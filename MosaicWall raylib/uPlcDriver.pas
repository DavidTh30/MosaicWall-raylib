unit uPlcDriver;

{ Live data source for the factory HMI: a Siemens S7 CPU (the Virtual PLC or a real one) over
  S7 communication (ISO-on-TCP, TCP 102), see SPEC_FactoryHMI.md section 9.

  The driver runs on its own thread. Every PeriodMs it reads the whole HMI data block in one
  Read Var telegram into a snapshot (under FLock), then sends the queued operator commands.
  The main thread calls Apply(Plant) once per frame: under the same lock it copies the snapshot
  into TPlant, so the screens and TPlant are only ever touched by the main thread.

  Commands are requests only: a pulse bit (CmdStart / CmdStop / CmdReset, LINE_CmdStart /
  LINE_CmdStop) that the PLC program clears when it has handled it, or a new SpeedSP. Every
  interlock (fault, over-temperature, reset allowed) is in the PLC. A command is dropped when the
  PLC heartbeat stands still (CPU in STOP), so it cannot fire minutes later on the next RUN.

  Data block layout (non-optimized DB, standard S7 offsets, big-endian), station i = 0..5 at
  i * STATION_SIZE:
    +0  State      Int   0 stopped 1 running 2 starved 3 blocked 4 fault 5 maintenance
    +2  FaultCode  Int   see FaultCodeText
    +4  Speed      Real  parts/min
    +8  SpeedSP    Real  parts/min (HMI writes)
    +12 Temp       Real  °C
    +16 Vib        Real  mm/s
    +20 Power      Real  kW
    +24 Count      DInt  parts processed
    +28 Reject     DInt  parts rejected
    +32 InBuf      Int   parts waiting in front of the station
    +34.0 CmdStart  +34.1 CmdStop  +34.2 CmdReset  (HMI sets, PLC clears)  +34.3 Enabled (status)
  then LINE at LINE_OFS:
    +0 Heartbeat Int (PLC counts every cycle)   +2.0 Running   +2.1 CmdStart   +2.2 CmdStop }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, uPlcClient, uPlantSim;

const
  STATION_SIZE = 36;
  LINE_OFS = STATION_COUNT * STATION_SIZE;   // 216
  DB_SIZE = LINE_OFS + 4;                     // 220 bytes, one telegram (PDU 480)

type
  TPlcStationIO = record
    State, FaultCode, InBuf: SmallInt;
    Speed, SpeedSP, Temp, Vib, Power: Single;
    Count, Reject: LongInt;
    Enabled: Boolean;
  end;

  TPlcSnapshot = record
    Stations: array[0..STATION_COUNT - 1] of TPlcStationIO;
    LineRunning: Boolean;
    Heartbeat: SmallInt;
    Online: Boolean;          // the last read succeeded
    FailCount: Integer;       // consecutive failed reads
    Reads: Int64;             // successful reads since start
  end;

  TPlcCmd = record
    Cmd: TPlantCommand;
    Station: Integer;
    Value: Single;
  end;

  { TPlcDriver }

  TPlcDriver = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnap: TPlcSnapshot;
    FQueue: array of TPlcCmd;
    FMsgs: TStringList;       // event log lines for the main thread
    FClient: TS7Client;
    FConnected: Boolean;
    FLastBeat: SmallInt;
    FBeatChangedAt: QWord;    // GetTickCount64 of the last heartbeat change
    procedure Msg(const S: string);
    function ConnectPlc: Boolean;
    function ReadAll(out S: TPlcSnapshot): Boolean;
    function SendCmd(const C: TPlcCmd): Boolean;
  protected
    procedure Execute; override;
  public
    Host: string;
    Port, Rack, Slot: Integer;   // Slot < 0: try 1, 2, 3, 0 (S7-1200/1500, 300, 400)
    DbNumber: Integer;
    PeriodMs: Integer;
    constructor Create(const AHost: string; ADbNumber, ASlot: Integer);
    destructor Destroy; override;
    // main thread
    procedure Post(Cmd: TPlantCommand; Station: Integer; Value: Single);
    procedure Apply(Plant: TPlant);
    procedure Shutdown;
  end;

implementation

function GetI16(const B: TBytes; Ofs: Integer): SmallInt;
begin
  Result := SmallInt((B[Ofs] shl 8) or B[Ofs + 1]);
end;

function GetI32(const B: TBytes; Ofs: Integer): LongInt;
begin
  Result := LongInt((LongWord(B[Ofs]) shl 24) or (LongWord(B[Ofs + 1]) shl 16) or
    (LongWord(B[Ofs + 2]) shl 8) or LongWord(B[Ofs + 3]));
end;

function GetReal(const B: TBytes; Ofs: Integer): Single;
var
  L: LongInt;
begin
  L := GetI32(B, Ofs);
  Move(L, Result, 4);
end;

function GetBit(const B: TBytes; Ofs, Bit: Integer): Boolean;
begin
  Result := (B[Ofs] shr Bit) and 1 <> 0;
end;

{ TPlcDriver }

constructor TPlcDriver.Create(const AHost: string; ADbNumber, ASlot: Integer);
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FMsgs := TStringList.Create;
  FClient := TS7Client.Create;
  FClient.TimeoutMs := 1000;
  Host := AHost;
  Port := 102;
  Rack := 0;
  Slot := ASlot;
  DbNumber := ADbNumber;
  PeriodMs := 200;
  inherited Create(False);
end;

destructor TPlcDriver.Destroy;
begin
  Shutdown;
  FClient.Free;
  FMsgs.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPlcDriver.Shutdown;
begin
  if Finished then Exit;
  Terminate;
  FWake.SetEvent;
  WaitFor;
end;

procedure TPlcDriver.Msg(const S: string);
begin
  FLock.Enter;
  try
    FMsgs.Add(S);
  finally
    FLock.Leave;
  end;
end;

procedure TPlcDriver.Post(Cmd: TPlantCommand; Station: Integer; Value: Single);
var
  n: Integer;
begin
  FLock.Enter;
  try
    n := Length(FQueue);
    SetLength(FQueue, n + 1);
    FQueue[n].Cmd := Cmd;
    FQueue[n].Station := Station;
    FQueue[n].Value := Value;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TPlcDriver.ConnectPlc: Boolean;
const
  AUTO_SLOTS: array[0..3] of Integer = (1, 2, 3, 0);
var
  i: Integer;
begin
  if Slot >= 0 then
    Result := FClient.Connect(Host, Port, Rack, Slot)
  else
  begin
    Result := False;
    for i := 0 to High(AUTO_SLOTS) do
      if FClient.Connect(Host, Port, Rack, AUTO_SLOTS[i]) then
      begin
        Slot := AUTO_SLOTS[i];
        Result := True;
        Break;
      end
      else if Pos('cannot connect', FClient.LastError) = 1 then
        Break;   // nobody listening on the port: no use trying other slots
  end;
end;

function TPlcDriver.ReadAll(out S: TPlcSnapshot): Boolean;
var
  B: TBytes;
  i, o: Integer;
begin
  S := Default(TPlcSnapshot);
  Result := (FClient.ReadArea($84, DbNumber, 0, DB_SIZE, B) = 0) and (Length(B) >= DB_SIZE);
  if not Result then Exit;
  for i := 0 to STATION_COUNT - 1 do
    with S.Stations[i] do
    begin
      o := i * STATION_SIZE;
      State := GetI16(B, o);
      FaultCode := GetI16(B, o + 2);
      Speed := GetReal(B, o + 4);
      SpeedSP := GetReal(B, o + 8);
      Temp := GetReal(B, o + 12);
      Vib := GetReal(B, o + 16);
      Power := GetReal(B, o + 20);
      Count := GetI32(B, o + 24);
      Reject := GetI32(B, o + 28);
      InBuf := GetI16(B, o + 32);
      Enabled := GetBit(B, o + 34, 3);
    end;
  S.Heartbeat := GetI16(B, LINE_OFS);
  S.LineRunning := GetBit(B, LINE_OFS + 2, 0);
end;

function TPlcDriver.SendCmd(const C: TPlcCmd): Boolean;
var
  o: Integer;
  L: LongInt;
  sp: Single;
begin
  o := C.Station * STATION_SIZE;
  case C.Cmd of
    pcStartLine: Result := FClient.WriteBit($84, DbNumber, LINE_OFS + 2, 1, True) = 0;
    pcStopLine: Result := FClient.WriteBit($84, DbNumber, LINE_OFS + 2, 2, True) = 0;
    pcStartStation: Result := FClient.WriteBit($84, DbNumber, o + 34, 0, True) = 0;
    pcStopStation: Result := FClient.WriteBit($84, DbNumber, o + 34, 1, True) = 0;
    pcResetStation: Result := FClient.WriteBit($84, DbNumber, o + 34, 2, True) = 0;
    pcSetSpeed:
      begin
        sp := C.Value;
        Move(sp, L, 4);
        Result := FClient.WriteArea($84, DbNumber, o + 8,
          [(L shr 24) and $FF, (L shr 16) and $FF, (L shr 8) and $FF, L and $FF]) = 0;
      end;
  else
    Result := False;
  end;
end;

procedure TPlcDriver.Execute;
var
  S: TPlcSnapshot;
  ok: Boolean;
  q: array of TPlcCmd;
  i, fails: Integer;
  reads: Int64;
  lastErr: string;
begin
  fails := 0;
  reads := 0;
  lastErr := '';
  while not Terminated do
  begin
    if not FConnected then
    begin
      FConnected := ConnectPlc;
      if FConnected then
      begin
        Msg(Format('PLC connected: %s rack %d slot %d, DB%d', [Host, Rack, Slot, DbNumber]));
        lastErr := '';
        FBeatChangedAt := 0;
      end;
    end;

    ok := FConnected and ReadAll(S);
    if ok then
    begin
      fails := 0;
      Inc(reads);
      if (FBeatChangedAt = 0) or (S.Heartbeat <> FLastBeat) then
      begin
        FLastBeat := S.Heartbeat;
        FBeatChangedAt := GetTickCount64;
      end;
    end
    else
    begin
      Inc(fails);
      if FClient.LastError <> lastErr then
      begin
        lastErr := FClient.LastError;
        Msg('PLC read failed: ' + lastErr);
      end;
      if FConnected then
      begin
        FClient.Close;
        FConnected := False;
      end;
    end;

    FLock.Enter;
    try
      if ok then FSnap := S;
      FSnap.Online := ok;
      FSnap.FailCount := fails;
      FSnap.Reads := reads;
      q := FQueue;
      FQueue := nil;
    finally
      FLock.Leave;
    end;

    // commands: only to a connected CPU whose program runs (heartbeat moved in the last 1.5 s)
    for i := 0 to High(q) do
      if not ok then
        Msg('Command not sent: PLC not connected')
      else if GetTickCount64 - FBeatChangedAt > 1500 then
        Msg('Command not sent: PLC program not running (CPU in STOP?)')
      else if not SendCmd(q[i]) then
        Msg('Command write failed: ' + FClient.LastError);

    if not Terminated then
      if ok then FWake.WaitFor(PeriodMs) else FWake.WaitFor(1000);   // retry the connection every second
  end;
  FClient.Close;
end;

procedure TPlcDriver.Apply(Plant: TPlant);
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to FMsgs.Count - 1 do Plant.LogEvent(FMsgs[i]);
    FMsgs.Clear;
    Plant.CommOk := FSnap.Online;
    Plant.CommFailures := FSnap.FailCount;
    if FSnap.Reads = 0 then Exit;   // nothing read yet: keep the model's start values
    Plant.LineRunning := FSnap.LineRunning;
    Plant.Good := FSnap.Stations[STATION_COUNT - 1].Count;
    Plant.Rejected := 0;
    for i := 0 to STATION_COUNT - 1 do
      with FSnap.Stations[i] do
      begin
        if (State >= Ord(Low(TStationState))) and (State <= Ord(High(TStationState))) then
          Plant.SetState(i, TStationState(State));
        Plant.Stations[i].Speed := Speed;
        Plant.Stations[i].SpeedSP := SpeedSP;
        Plant.Stations[i].Temp := Temp;
        Plant.Stations[i].Vib := Vib;
        Plant.Stations[i].Power := Power;
        Plant.Stations[i].Processed := Count;
        Plant.Stations[i].Rejects := Reject;
        Plant.Stations[i].InBuf := InBuf;
        Plant.Stations[i].Enabled := Enabled;
        if State = Ord(ssFault) then
          Plant.Stations[i].FaultText := FaultCodeText(FaultCode)
        else
          Plant.Stations[i].FaultText := '';
        Plant.Stations[i].RepairAt := Plant.SimTime;
        Plant.Rejected := Plant.Rejected + Reject;
      end;
  finally
    FLock.Leave;
  end;
end;

end.
