unit uPlantSim;

{ Simulated production line for the factory HMI.

  Six stations in series with small part buffers between them. Each running station takes a
  part from its input buffer and puts it into its output buffer at its actual speed, so a
  stopped or faulted station starves the stations after it and blocks the ones before it.
  Temperatures and vibration follow the load with first-order lag and noise; crossing a limit
  raises an alarm, crossing the trip limit faults the station. Random faults happen too, and an
  unattended fault is repaired by "maintenance" after a while so the demo keeps running.

  Live mode (Live = True, see uPlcDriver.pas): a PLC driver copies the station values into
  TPlant, Update() only derives alarms, KPIs and trends from them, and the operator commands
  go to OnCommand (the driver's queue) instead of changing the model. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uAlarms;

const
  STATION_COUNT = 6;
  BUFFER_CAP = 12;
  TREND_CAP = 600;            // 120 s at 5 samples/s
  TREND_HZ = 5;
  IDEAL_RATE = 60.0;          // parts/min the line is designed for
  SHIFT_HOURS = 8;

type
  TStationState = (ssStopped, ssRunning, ssStarved, ssBlocked, ssFault, ssMaint);

  TPlantCommand = (pcStartLine, pcStopLine, pcStartStation, pcStopStation, pcResetStation, pcSetSpeed);
  TPlantCommandEvent = procedure(Cmd: TPlantCommand; Station: Integer; Value: Single) of object;

  TStation = record
    Code, Name: string;
    State: TStationState;
    StateSince: Double;       // sim time of last state change
    SpeedSP, Speed, SpeedMax: Single;  // parts/min
    Temp, TempAmbient, TempRise, TempHi, TempTrip: Single;
    Vib, VibHi: Single;       // mm/s
    Power, PowerRated: Single;  // kW
    Processed, Rejects: Int64;
    InBuf: Integer;           // parts waiting in front of this station
    Progress: Double;         // fraction of the current part
    FaultText: string;
    RepairAt: Double;         // sim time when maintenance arrives / finishes
    RunTime: Double;
    Enabled: Boolean;         // operator start command
    TempHiTimer, VibHiTimer: Double;   // alarm on-delay timers (s)
    VibExtra, VibExtraUntil: Double;   // bearing wear episode (Press)
  end;

  TTrend = class
  private
    FData: array[0..TREND_CAP - 1] of Single;
    FHead, FCount: Integer;
  public
    Name, Units: string;
    MinV, MaxV, LoLimit, HiLimit: Single;   // limits 0 = none
    constructor Create(const AName, AUnits: string; AMin, AMax, ALo, AHi: Single);
    procedure Push(v: Single);
    function Get(i: Integer): Single;       // 0 = oldest
    function Last: Single;
    property Count: Integer read FCount;
  end;

  TPlant = class
  private
    FRng: QWord;
    FTrendAcc: Double;
    FMinuteAcc: Double;
    FGoodLastMin: array[0..59] of Integer;  // parts per second ring for output rate
    FGoodThisSec: Integer;
    FSecAcc: Double;
    FSecIdx: Integer;
    FLastGood: Int64;                 // live mode: Good at the last update (-1: not seen yet)
    function Rnd: Double;
    function Gauss: Double;
    procedure UpdateStation(i: Integer; dt: Double);
    procedure CheckLimits(i: Integer; dt: Double);
    procedure Fault(i: Integer; const Why: string);
    procedure UpdateLive(dt: Double);
    function SendCommand(Cmd: TPlantCommand; Station: Integer; Value: Single; const What: string): Boolean;
  public
    Stations: array[0..STATION_COUNT - 1] of TStation;
    Alarms: TAlarmManager;
    Events: TStringList;
    Trends: array[0..3] of TTrend;    // output rate, ST30 temp, total power, ST20 vibration
    SimTime: Double;
    ShiftStart: TDateTime;
    LineRunning: Boolean;
    Good, Rejected: Int64;
    LineRunTime: Double;
    RateLoTimer: Double;              // time the last station was producing
    // live mode: values written by the PLC driver (main thread, under the driver's lock)
    Live: Boolean;
    PlcName: string;                  // shown in the comm alarm, e.g. 'PLC 127.0.0.1'
    CommOk: Boolean;                  // last read succeeded
    CommFailures: Integer;            // consecutive failed reads
    OnCommand: TPlantCommandEvent;
    constructor Create;
    destructor Destroy; override;
    procedure Update(dt: Double);
    procedure SetState(i: Integer; S: TStationState);
    // operator commands
    procedure StartLine;
    procedure StopLine;
    procedure StartStation(i: Integer);
    procedure StopStation(i: Integer);
    procedure ResetStation(i: Integer);
    procedure SetSpeed(i: Integer; sp: Single);
    procedure LogEvent(const Msg: string);
    function Clock: TDateTime;        // plant time: shift start + simulated seconds
    // KPIs
    function OutputRate: Single;      // good parts/min over the last 60 s
    function TotalPower: Single;
    function Availability: Single;
    function Performance: Single;
    function Quality: Single;
    function OEE: Single;
    function ShiftTarget: Int64;      // parts planned for the whole shift
    function ExpectedByNow: Int64;    // parts planned up to now
    procedure SaveReportCsv(const FileName: string);
  end;

const
  STATE_TEXT: array[TStationState] of string =
    ('STOPPED', 'RUNNING', 'STARVED', 'BLOCKED', 'FAULT', 'MAINTENANCE');
  COMM_FAIL_LIMIT = 3;        // failed PLC reads before "Communication lost"

// the fault text of a PLC FaultCode (1..6 the random faults of the simulation, 7 over-temperature)
function FaultCodeText(Code: Integer): string;

implementation

uses
  Math;

const
  FAULTS: array[0..5] of string = ('motor overload', 'part jam detected', 'proximity sensor lost',
    'safety door opened', 'servo drive error', 'air pressure low');

function FaultCodeText(Code: Integer): string;
begin
  case Code of
    1..6: Result := FAULTS[Code - 1];
    7: Result := 'over-temperature trip';
  else
    Result := Format('fault code %d', [Code]);
  end;
end;

{ TTrend }

constructor TTrend.Create(const AName, AUnits: string; AMin, AMax, ALo, AHi: Single);
begin
  inherited Create;
  Name := AName; Units := AUnits;
  MinV := AMin; MaxV := AMax; LoLimit := ALo; HiLimit := AHi;
end;

procedure TTrend.Push(v: Single);
begin
  FData[FHead] := v;
  FHead := (FHead + 1) mod TREND_CAP;
  if FCount < TREND_CAP then Inc(FCount);
end;

function TTrend.Get(i: Integer): Single;
begin
  Result := FData[(FHead - FCount + i + TREND_CAP) mod TREND_CAP];
end;

function TTrend.Last: Single;
begin
  if FCount = 0 then Result := 0 else Result := Get(FCount - 1);
end;

{ TPlant }

procedure InitStation(var S: TStation; const ACode, AName: string;
  ASpeedMax, ARise, AHi, ATrip, AVibHi, APower: Single);
begin
  S.Code := ACode; S.Name := AName;
  S.State := ssStopped;
  S.SpeedMax := ASpeedMax; S.SpeedSP := Min(ASpeedMax, 62); S.Speed := 0;
  S.TempAmbient := 32; S.Temp := 32; S.TempRise := ARise; S.TempHi := AHi; S.TempTrip := ATrip;
  S.Vib := 0.8; S.VibHi := AVibHi;
  S.PowerRated := APower; S.Power := 0;
  S.InBuf := 4;
  S.Enabled := False;
end;

constructor TPlant.Create;
begin
  inherited Create;
  FRng := 88172645463325252;
  Alarms := TAlarmManager.Create;
  Events := TStringList.Create;
  InitStation(Stations[0], 'ST10', 'Feeder',        80, 18,  70,  80, 7.0, 4.5);
  InitStation(Stations[1], 'ST20', 'Press',         70, 38,  78,  88, 6.5, 22);
  InitStation(Stations[2], 'ST30', 'Welder',        70, 52,  86,  95, 7.0, 35);
  InitStation(Stations[3], 'ST40', 'Paint Booth',   75, 28,  60,  68, 5.0, 18);
  InitStation(Stations[4], 'ST50', 'Vision Inspect', 90, 12, 55,  62, 4.0, 2.5);
  InitStation(Stations[5], 'ST60', 'Packer',        80, 16,  65,  75, 6.0, 6);
  Trends[0] := TTrend.Create('Line output', 'parts/min', 0, 80, 45, 0);
  Trends[1] := TTrend.Create('ST30 Welder temperature', '°C', 20, 100, 0, 86);
  Trends[2] := TTrend.Create('Total power', 'kW', 0, 100, 0, 85);
  Trends[3] := TTrend.Create('ST20 Press vibration', 'mm/s', 0, 10, 0, 6.5);
  ShiftStart := Now;
  FLastGood := -1;
  CommOk := True;
  LogEvent('HMI started, line stopped');
end;

destructor TPlant.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Trends) do Trends[i].Free;
  Alarms.Free;
  Events.Free;
  inherited Destroy;
end;

function TPlant.Rnd: Double;
begin
  // xorshift64: own generator so the simulation never touches the global Random
  FRng := FRng xor (FRng shl 13);
  FRng := FRng xor (FRng shr 7);
  FRng := FRng xor (FRng shl 17);
  Result := (FRng shr 11) / 9007199254740992.0;
end;

function TPlant.Gauss: Double;
begin
  Result := Rnd + Rnd + Rnd - 1.5;   // cheap approx. normal, sd ~0.5
end;

function TPlant.Clock: TDateTime;
begin
  Result := ShiftStart + SimTime / 86400;
end;

procedure TPlant.LogEvent(const Msg: string);
begin
  Events.Add(FormatDateTime('hh:nn:ss', Clock) + '  ' + Msg);
  while Events.Count > 500 do Events.Delete(0);
end;

procedure TPlant.SetState(i: Integer; S: TStationState);
begin
  if Stations[i].State = S then Exit;
  Stations[i].State := S;
  Stations[i].StateSince := SimTime;
end;

procedure TPlant.Fault(i: Integer; const Why: string);
begin
  with Stations[i] do
  begin
    FaultText := Why;
    RepairAt := SimTime + 45 + Rnd * 30;   // maintenance arrives if nobody resets it
  end;
  SetState(i, ssFault);
  Alarms.RaiseAlarm(Stations[i].Code + '.FAULT', Stations[i].Code,
    Stations[i].Name + ' fault: ' + Why, apCritical, Clock);
  LogEvent(Stations[i].Code + ' FAULT - ' + Why);
end;

procedure TPlant.CheckLimits(i: Integer; dt: Double);
const
  ON_DELAY = 3.0;   // s over the limit before the alarm is raised (ISA-18.2 on-delay)
begin
  with Stations[i] do
  begin
    if Temp > TempHi then TempHiTimer := TempHiTimer + dt else TempHiTimer := 0;
    if TempHiTimer >= ON_DELAY then
      Alarms.RaiseAlarm(Code + '.TEMP_HI', Code, Format('%s high temperature %.0f °C (limit %.0f)', [Name, Temp, TempHi]), apHigh, Clock)
    else if Temp < TempHi - 3 then
      Alarms.ClearAlarm(Code + '.TEMP_HI', Clock);
    if Vib > VibHi then VibHiTimer := VibHiTimer + dt else VibHiTimer := 0;
    if VibHiTimer >= ON_DELAY then
      Alarms.RaiseAlarm(Code + '.VIB_HI', Code, Format('%s high vibration %.1f mm/s (limit %.1f)', [Name, Vib, VibHi]), apMedium, Clock)
    else if Vib < VibHi - 0.8 then
      Alarms.ClearAlarm(Code + '.VIB_HI', Clock);
    if (State in [ssRunning, ssStarved, ssBlocked]) and (Temp > TempTrip) then
      Fault(i, Format('over-temperature trip %.0f °C', [Temp]));
  end;
end;

procedure TPlant.UpdateStation(i: Integer; dt: Double);
const
  FAULT_RATE = 1 / 900;      // random faults per station-second while running (demo rate: ~1 per 2.5 min per line)
var
  load, target, rate: Double;
  canTake, canPut: Boolean;
begin
  with Stations[i] do
  begin
    // --- state machine
    case State of
      ssFault:
        if SimTime >= RepairAt then
        begin
          SetState(i, ssMaint);
          RepairAt := SimTime + 15 + Rnd * 15;
          LogEvent(Code + ' maintenance started');
        end;
      ssMaint:
        if SimTime >= RepairAt then
        begin
          FaultText := '';
          Alarms.ClearAlarm(Code + '.FAULT', Clock);
          SetState(i, ssStopped);
          LogEvent(Code + ' maintenance finished');
        end;
    end;

    if State in [ssStopped, ssRunning, ssStarved, ssBlocked] then
    begin
      canTake := (i = 0) or (InBuf > 0);
      canPut := (i = STATION_COUNT - 1) or (Stations[i + 1].InBuf < BUFFER_CAP);
      if not (Enabled and LineRunning) then SetState(i, ssStopped)
      else if not canTake then SetState(i, ssStarved)
      else if not canPut then SetState(i, ssBlocked)
      else SetState(i, ssRunning);
    end;

    // --- speed and parts
    if State = ssRunning then
      Speed := Speed + (SpeedSP - Speed) * Min(1, dt * 1.5)
    else
      Speed := Speed * Max(0, 1 - dt * 3);
    if State = ssRunning then
    begin
      Progress := Progress + Speed / 60 * dt;
      while Progress >= 1 do
      begin
        Progress := Progress - 1;
        if i > 0 then Dec(InBuf);
        Inc(Processed);
        if i = 4 then
        begin
          // vision inspection rejects more parts when the welder runs hot
          rate := 0.015 + Max(0, Stations[2].Temp - 80) * 0.01;
          if Rnd < rate then
          begin
            Inc(Rejects); Inc(Rejected);
            Continue;      // rejected part leaves the line
          end;
        end;
        if i < STATION_COUNT - 1 then
          Inc(Stations[i + 1].InBuf)
        else
        begin
          Inc(Good);
          Inc(FGoodThisSec);
        end;
        if (InBuf <= 0) and (i > 0) then begin Progress := 0; Break; end;
      end;
      RunTime := RunTime + dt;
      if i = STATION_COUNT - 1 then LineRunTime := LineRunTime + dt;
      if Rnd < FAULT_RATE * dt then
        Fault(i, FAULTS[Trunc(Rnd * Length(FAULTS)) mod Length(FAULTS)]);
    end;

    // --- process values
    load := Speed / SpeedMax;
    target := TempAmbient + TempRise * load * (0.9 + 0.25 * (SpeedSP / SpeedMax));
    Temp := Temp + (target - Temp) * Min(1, dt / 20) + Gauss * 0.15;
    // bearing wear episode on the press: vibration rises for 40-80 s (a real reason to alarm)
    if (i = 1) and (State = ssRunning) and (VibExtraUntil < SimTime) and (Rnd < dt / 300) then
    begin
      VibExtra := 3.2 + Rnd * 1.5;
      VibExtraUntil := SimTime + 40 + Rnd * 40;
    end;
    if VibExtraUntil < SimTime then VibExtra := 0;
    Vib := Vib + ((0.6 + 4.2 * load * load + VibExtra * load) - Vib) * Min(1, dt * 2) + Gauss * 0.12 * (0.3 + load);
    if (State = ssRunning) and (Rnd < 0.01 * dt) then Vib := Vib + 1.5 + Rnd * 1.5;   // short knock, below the on-delay
    if Vib < 0 then Vib := 0;
    if State = ssRunning then Power := PowerRated * (0.25 + 0.75 * load)
    else if State in [ssStarved, ssBlocked] then Power := PowerRated * 0.2
    else Power := PowerRated * 0.05;
  end;
  CheckLimits(i, dt);
end;

procedure TPlant.Update(dt: Double);
var
  i: Integer;
begin
  if dt > 0.25 then dt := 0.25;   // window drag / pause: don't jump the simulation
  SimTime := SimTime + dt;
  if Live then
    UpdateLive(dt)
  else
    for i := 0 to STATION_COUNT - 1 do
      UpdateStation(i, dt);

  // parts per second ring -> output rate
  FSecAcc := FSecAcc + dt;
  while FSecAcc >= 1 do
  begin
    FSecAcc := FSecAcc - 1;
    FGoodLastMin[FSecIdx] := FGoodThisSec;
    FGoodThisSec := 0;
    FSecIdx := (FSecIdx + 1) mod 60;
  end;

  // low output only counts once the line has run a full minute, with a 10 s on-delay
  if LineRunning and (OutputRate < 45) and (LineRunTime > 60) then
    RateLoTimer := RateLoTimer + dt
  else
    RateLoTimer := 0;
  if RateLoTimer >= 10 then
    Alarms.RaiseAlarm('LINE.RATE_LO', 'LINE', Format('Line output %.0f parts/min, below 45', [OutputRate]), apMedium, Clock)
  else if OutputRate > 48 then
    Alarms.ClearAlarm('LINE.RATE_LO', Clock);

  FTrendAcc := FTrendAcc + dt;
  while FTrendAcc >= 1 / TREND_HZ do
  begin
    FTrendAcc := FTrendAcc - 1 / TREND_HZ;
    Trends[0].Push(OutputRate);
    Trends[1].Push(Stations[2].Temp);
    Trends[2].Push(TotalPower);
    Trends[3].Push(Stations[1].Vib);
  end;
end;

{ Live mode: the driver has copied State, Speed, Temp ... into Stations (Apply). Here only what
  the HMI derives from them: state times, fault and limit alarms, run times, output rate. }
procedure TPlant.UpdateLive(dt: Double);
var
  i: Integer;
begin
  if CommFailures >= COMM_FAIL_LIMIT then
    Alarms.RaiseAlarm('PLC.COMM', 'PLC', 'Communication lost: ' + PlcName + ' not answering', apCritical, Clock)
  else if CommOk then
    Alarms.ClearAlarm('PLC.COMM', Clock);
  if not CommOk then Exit;    // stale values: no process alarms, no run time

  // output rate from the PLC's counter (the first value seen is the start, not a burst)
  if (FLastGood >= 0) and (Good >= FLastGood) then
    Inc(FGoodThisSec, Good - FLastGood);
  FLastGood := Good;

  for i := 0 to STATION_COUNT - 1 do
    with Stations[i] do
    begin
      if State = ssFault then
        Alarms.RaiseAlarm(Code + '.FAULT', Code, Name + ' fault: ' + FaultText, apCritical, Clock)
      else
        Alarms.ClearAlarm(Code + '.FAULT', Clock);
      if State = ssRunning then
      begin
        RunTime := RunTime + dt;
        if i = STATION_COUNT - 1 then LineRunTime := LineRunTime + dt;
      end;
      CheckLimits(i, dt);
    end;
end;

{ Live mode: hand an operator command to the driver; the PLC decides (interlocks stay there). }
function TPlant.SendCommand(Cmd: TPlantCommand; Station: Integer; Value: Single; const What: string): Boolean;
begin
  Result := Live;
  if not Live then Exit;
  if Assigned(OnCommand) then OnCommand(Cmd, Station, Value);
  if CommOk then
    LogEvent('Operator: ' + What + ' - request sent to PLC')
  else
    LogEvent('Operator: ' + What + ' - queued, PLC not connected');
end;

procedure TPlant.StartLine;
var
  i: Integer;
begin
  if SendCommand(pcStartLine, -1, 0, 'START LINE') then Exit;
  LineRunning := True;
  for i := 0 to STATION_COUNT - 1 do Stations[i].Enabled := True;
  LogEvent('Operator: START LINE');
end;

procedure TPlant.StopLine;
begin
  if SendCommand(pcStopLine, -1, 0, 'STOP LINE') then Exit;
  LineRunning := False;
  LogEvent('Operator: STOP LINE');
end;

procedure TPlant.StartStation(i: Integer);
begin
  if SendCommand(pcStartStation, i, 0, 'start ' + Stations[i].Code) then Exit;
  Stations[i].Enabled := True;
  LogEvent('Operator: start ' + Stations[i].Code);
end;

procedure TPlant.StopStation(i: Integer);
begin
  if SendCommand(pcStopStation, i, 0, 'stop ' + Stations[i].Code) then Exit;
  Stations[i].Enabled := False;
  LogEvent('Operator: stop ' + Stations[i].Code);
end;

procedure TPlant.ResetStation(i: Integer);
begin
  if SendCommand(pcResetStation, i, 0, 'reset ' + Stations[i].Code) then Exit;
  with Stations[i] do
    if State = ssFault then
    begin
      if Temp > TempTrip - 2 then
      begin
        LogEvent('Operator: reset ' + Code + ' refused - still too hot');
        Exit;
      end;
      FaultText := '';
      Alarms.ClearAlarm(Code + '.FAULT', Clock);
      SetState(i, ssStopped);
      LogEvent('Operator: reset ' + Code);
    end;
end;

procedure TPlant.SetSpeed(i: Integer; sp: Single);
begin
  with Stations[i] do
  begin
    SpeedSP := EnsureRange(sp, 10, SpeedMax);
    if SendCommand(pcSetSpeed, i, SpeedSP, Format('%s speed setpoint %.0f parts/min', [Code, SpeedSP])) then Exit;
    LogEvent(Format('Operator: %s speed setpoint %.0f parts/min', [Code, SpeedSP]));
  end;
end;

function TPlant.OutputRate: Single;
var
  i, n: Integer;
begin
  n := 0;
  for i := 0 to 59 do Inc(n, FGoodLastMin[i]);
  Result := n * 60 / Min(60, Max(1, SimTime));
end;

function TPlant.TotalPower: Single;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to STATION_COUNT - 1 do Result := Result + Stations[i].Power;
end;

function TPlant.Availability: Single;
begin
  if SimTime <= 0 then Exit(0);
  Result := LineRunTime / SimTime;
end;

function TPlant.Performance: Single;
begin
  if LineRunTime <= 1 then Exit(0);
  Result := Min(1, (Good + Rejected) / (LineRunTime / 60 * IDEAL_RATE));
end;

function TPlant.Quality: Single;
begin
  if Good + Rejected = 0 then Exit(1);
  Result := Good / (Good + Rejected);
end;

function TPlant.OEE: Single;
begin
  Result := Availability * Performance * Quality;
end;

function TPlant.ShiftTarget: Int64;
begin
  Result := Round(SHIFT_HOURS * 60 * IDEAL_RATE * 0.85);
end;

function TPlant.ExpectedByNow: Int64;
begin
  Result := Round(SimTime / 60 * IDEAL_RATE * 0.85);
end;

procedure TPlant.SaveReportCsv(const FileName: string);
var
  L: TStringList;
  i: Integer;
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  L := TStringList.Create;
  try
    L.Add('section,item,value');
    L.Add('shift,start,' + FormatDateTime('yyyy-mm-dd hh:nn:ss', ShiftStart));
    L.Add(Format('shift,elapsed_s,%.0f', [SimTime], fs));
    L.Add(Format('kpi,oee_pct,%.1f', [OEE * 100], fs));
    L.Add(Format('kpi,availability_pct,%.1f', [Availability * 100], fs));
    L.Add(Format('kpi,performance_pct,%.1f', [Performance * 100], fs));
    L.Add(Format('kpi,quality_pct,%.2f', [Quality * 100], fs));
    L.Add(Format('kpi,good,%d', [Good]));
    L.Add(Format('kpi,rejected,%d', [Rejected]));
    L.Add(Format('kpi,output_rate_ppm,%.1f', [OutputRate], fs));
    L.Add(Format('kpi,power_kw,%.1f', [TotalPower], fs));
    for i := 0 to STATION_COUNT - 1 do
      with Stations[i] do
      begin
        L.Add(Format('%s,state,%s', [Code, STATE_TEXT[State]]));
        L.Add(Format('%s,speed_sp,%.0f', [Code, SpeedSP], fs));
        L.Add(Format('%s,temp_c,%.1f', [Code, Temp], fs));
        L.Add(Format('%s,vibration_mms,%.2f', [Code, Vib], fs));
        L.Add(Format('%s,processed,%d', [Code, Processed]));
        L.Add(Format('%s,run_time_s,%.0f', [Code, RunTime], fs));
      end;
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
end;

end.
