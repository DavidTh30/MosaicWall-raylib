unit uFactoryHmi;

{ Factory HMI screens on top of the MosaicWall background.

  Layout is designed at 1600x900 and scaled to the window with a Camera2D (letterboxed),
  so it works from 1280x720 up to 4K. The mosaic is drawn first at full resolution, calmed
  with a dark veil and slow motion, so the process data stays the most visible thing.

  Screens: F1 Overview (KPIs, process flow, station table, station detail)
           F2 Trends   (4 live trends, 120 s, limits, hover read-out)
           F3 Alarms   (active / history / event log, acknowledge, export)
  Always visible: top bar (navigation, clock, shift, SIMULATION or ONLINE / OFFLINE badge) and the alarm banner. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, raylib, uMosaicTypes, uMosaicRender, uPlantSim, uAlarms, uPlcDriver;

const
  DESIGN_W = 1600;
  DESIGN_H = 900;

type
  THmiScreen = (scOverview, scTrends, scAlarms);
  TAlarmView = (avActive, avHistory, avEvents);
  TConfirmAction = (caNone, caStartLine, caStopLine, caStartStation, caStopStation);

  TFactoryHmi = class
  private
    FCfg: TMosaicConfig;
    FMosaic: TMosaic;
    FRenderer: TMosaicRenderer;
    FBgW, FBgH: Integer;
    FTime: Double;
    FBlink: Boolean;
    FSel: Integer;
    FAlarmView: TAlarmView;
    FAlarmScroll: Single;
    FAlarmSel: Integer;
    FConfirm: TConfirmAction;
    FConfirmText: string;
    FConfirmStation: Integer;
    FToast: string;
    FToastUntil: Double;
    FZoom, FOffX, FOffY: Single;
    FDriver: TPlcDriver;
    procedure EnsureBackground(W, H: Integer);
    procedure Ask(A: TConfirmAction; Station: Integer; const Text: string);
    procedure DoConfirmed;
    procedure Toast(const S: string);
    procedure ScissorDesign(const R: TRectangle);
    procedure DrawTopBar;
    procedure DrawOverview;
    procedure DrawKpis(const R: TRectangle);
    procedure DrawRing(const R: TRectangle; const Title, Sub: string; V, Target: Single);
    procedure DrawProcessFlow(const R: TRectangle);
    procedure DrawStationTile(i: Integer; const R: TRectangle);
    procedure DrawStationTable(const R: TRectangle);
    procedure DrawStationDetail(const R: TRectangle);
    procedure DrawBar(const R: TRectangle; const L: string; V, MaxV, Hi, Trip: Single; const Units: string);
    procedure DrawTrends;
    procedure DrawChart(T: TTrend; const R: TRectangle);
    procedure DrawAlarms;
    procedure DrawBanner;
    procedure DrawConfirm;
    procedure DrawToast;
  public
    Plant: TPlant;
    Screen: THmiScreen;
    ShowMosaic: Boolean;
    ExportDir: string;
    constructor Create;
    destructor Destroy; override;
    procedure HandleKeys;
    // live data from an S7 PLC instead of the simulation (Slot < 0: auto)
    procedure ConnectPlc(const Host: string; DbNumber, Slot: Integer);
    procedure Update(dt: Double);
    // full frame for a W x H target (window or render texture); call between Begin/End drawing
    procedure Draw(W, H: Integer);
    procedure ExportReport;
    procedure Screenshot;
    property Selected: Integer read FSel write FSel;
  end;

implementation

uses
  Math, uMosaicGen, uHmiTheme, uHmiWidgets;

function Pick(Cond: Boolean; const A, B: TColor): TColor;
begin
  if Cond then Result := A else Result := B;
end;

function Pick2(Cond: Boolean; const A, B: string): string;
begin
  if Cond then Result := A else Result := B;
end;

function Pct(v: Single): string;
begin
  Result := Format('%.1f%%', [v * 100]);
end;

function ShiftName(t: TDateTime): string;
var
  h: Integer;
begin
  h := StrToInt(FormatDateTime('h', t));
  if (h >= 6) and (h < 14) then Result := 'Shift A  06–14'
  else if (h >= 14) and (h < 22) then Result := 'Shift B  14–22'
  else Result := 'Shift C  22–06';
end;

{ TFactoryHmi }

constructor TFactoryHmi.Create;
begin
  inherited Create;
  Plant := TPlant.Create;
  FCfg := DefaultMosaicConfig;
  // calm background: smaller tiles for landscape, slow motion, stronger vignette
  FCfg.CellRatio := 0.042;
  FCfg.Motion := 0.35;
  FCfg.Vignette := 0.25;
  FCfg.GlowMode := 1;
  ShowMosaic := True;
  FSel := 2;
  FAlarmSel := -1;
  ExportDir := ExtractFilePath(ParamStr(0)) + 'export';
end;

destructor TFactoryHmi.Destroy;
begin
  FDriver.Free;
  FRenderer.Free;
  Plant.Free;
  inherited Destroy;
end;

procedure TFactoryHmi.EnsureBackground(W, H: Integer);
begin
  if FRenderer = nil then FRenderer := TMosaicRenderer.Create;
  if (W <> FBgW) or (H <> FBgH) then
  begin
    GenerateMosaic(FCfg, W, H, FMosaic);
    FBgW := W; FBgH := H;
  end;
end;

procedure TFactoryHmi.Toast(const S: string);
begin
  FToast := S;
  FToastUntil := FTime + 4;
end;

procedure TFactoryHmi.Ask(A: TConfirmAction; Station: Integer; const Text: string);
begin
  FConfirm := A;
  FConfirmStation := Station;
  FConfirmText := Text;
end;

procedure TFactoryHmi.DoConfirmed;
begin
  case FConfirm of
    caStartLine: Plant.StartLine;
    caStopLine: Plant.StopLine;
    caStartStation: Plant.StartStation(FConfirmStation);
    caStopStation: Plant.StopStation(FConfirmStation);
  end;
  FConfirm := caNone;
end;

procedure TFactoryHmi.ExportReport;
var
  ts, base: string;
begin
  ForceDirectories(ExportDir);
  ts := FormatDateTime('yyyymmdd_hhnnss', Now);
  base := IncludeTrailingPathDelimiter(ExportDir) + 'hmi_' + ts;
  Plant.SaveReportCsv(base + '_report.csv');
  Plant.Alarms.SaveCsv(base + '_alarms.csv');
  Plant.Events.SaveToFile(base + '_events.txt');
  Plant.LogEvent('Report exported: hmi_' + ts + '_*.csv');
  Toast('Report exported to export\hmi_' + ts + '_*');
end;

procedure TFactoryHmi.Screenshot;
var
  f: string;
begin
  // raylib saves screenshots next to the exe
  f := 'hmi_screen_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.png';
  TakeScreenshot(PChar(f));
  Toast('Screenshot saved: ' + f);
end;

procedure TFactoryHmi.HandleKeys;
begin
  if IsKeyPressed(KEY_F1) or IsKeyPressed(KEY_ONE) then Screen := scOverview;
  if IsKeyPressed(KEY_F2) or IsKeyPressed(KEY_TWO) then Screen := scTrends;
  if IsKeyPressed(KEY_F3) or IsKeyPressed(KEY_THREE) then Screen := scAlarms;
  if IsKeyPressed(KEY_B) then ShowMosaic := not ShowMosaic;
  if IsKeyPressed(KEY_F12) then Screenshot;
  if IsKeyPressed(KEY_ESCAPE) and (FConfirm <> caNone) then FConfirm := caNone;
end;

procedure TFactoryHmi.ConnectPlc(const Host: string; DbNumber, Slot: Integer);
begin
  FDriver := TPlcDriver.Create(Host, DbNumber, Slot);
  Plant.Live := True;
  Plant.CommOk := False;
  Plant.PlcName := 'PLC ' + Host;
  Plant.OnCommand := @FDriver.Post;
  Plant.LogEvent(Format('Data source: S7 PLC %s, DB%d', [Host, DbNumber]));
end;

procedure TFactoryHmi.Update(dt: Double);
begin
  FTime := FTime + dt;
  FBlink := Frac(FTime) > 0.5;
  if FDriver <> nil then FDriver.Apply(Plant);
  Plant.Update(dt);
end;

procedure TFactoryHmi.ScissorDesign(const R: TRectangle);
begin
  BeginScissorMode(Round(R.x * FZoom + FOffX), Round(R.y * FZoom + FOffY),
    Round(R.width * FZoom), Round(R.height * FZoom));
end;

{ ---------------------------------------------------------------- frame }

procedure TFactoryHmi.Draw(W, H: Integer);
var
  cam: TCamera2D;
begin
  ClearBackground(C_BG);
  if ShowMosaic then
  begin
    EnsureBackground(W, H);
    FRenderer.DrawScene(FMosaic, FCfg, FTime);
    DrawRectangle(0, 0, W, H, C_VEIL);
  end;

  FZoom := Min(W / DESIGN_W, H / DESIGN_H);
  FOffX := (W - DESIGN_W * FZoom) / 2;
  FOffY := (H - DESIGN_H * FZoom) / 2;
  UiModalLayer := Ord(FConfirm <> caNone);
  UiBeginFrame(FZoom, FOffX, FOffY);

  cam.offset := Vec2(FOffX, FOffY);
  cam.target := Vec2(0, 0);
  cam.rotation := 0;
  cam.zoom := FZoom;
  BeginMode2D(cam);
    DrawTopBar;
    case Screen of
      scOverview: DrawOverview;
      scTrends: DrawTrends;
      scAlarms: DrawAlarms;
    end;
    DrawBanner;
    DrawToast;
    if FConfirm <> caNone then DrawConfirm;
  EndMode2D;
  UiEndFrame;
end;

{ ---------------------------------------------------------------- top bar }

procedure TFactoryHmi.DrawTopBar;
var
  tabs: array[0..2] of string = ('Overview', 'Trends', 'Alarms');
  hints: array[0..2] of string = ('F1', 'F2', 'F3');
  i, unack: Integer;
  r: TRectangle;
  badgeC: TColor;
begin
  DrawRectangle(0, 0, DESIGN_W, 62, C_TOPBAR);
  DrawRectangle(0, 62, DESIGN_W, 1, C_RIM);
  MosaicLogo(20, 12, 38);
  Txt(FontBold, 'PLANT 3  ·  ASSEMBLY LINE A', 70, 10, 21, C_TEXT);
  Txt(FontUI, 'Production monitoring HMI', 70, 36, 13, C_MUTED);

  unack := Plant.Alarms.UnackCount;
  if Plant.Alarms.OpenCountOf(apCritical) > 0 then badgeC := C_CRIT
  else if Plant.Alarms.OpenCountOf(apHigh) > 0 then badgeC := C_HIGH
  else badgeC := C_MED;
  for i := 0 to 2 do
  begin
    r := Rect(560 + i * 166, 9, 156, 46);
    if Tab(r, tabs[i], hints[i], Ord(Screen) = i, IfThen(i = 2, Plant.Alarms.OpenCount, 0), badgeC) then
      Screen := THmiScreen(i);
  end;
  if (unack > 0) and FBlink then
    DrawRectangleRoundedLinesEx(Rect(560 + 2 * 166, 9, 156, 46), 0.25, 6, 2, badgeC);

  // data source badge: operators must never mistake demo data for the live plant,
  // nor stale values for live ones (OFFLINE is an alarm condition, so it gets the alarm colour)
  r := Rect(1110, 16, 128, 30);
  if not Plant.Live then
  begin
    DrawRectangleRoundedLinesEx(r, 0.3, 6, 1.5, C_HIGH);
    TxtIn(FontBold, 'SIMULATION', r, 13, C_HIGH, haCenter);
  end
  else if Plant.CommOk then
  begin
    DrawRectangleRoundedLinesEx(r, 0.3, 6, 1.5, C_RIM);
    TxtIn(FontBold, 'ONLINE', r, 13, C_TEXT2, haCenter);
  end
  else
  begin
    if FBlink then DrawRectangleRounded(r, 0.3, 6, Fade(C_CRIT, 90));
    DrawRectangleRoundedLinesEx(r, 0.3, 6, 1.5, C_CRIT);
    TxtIn(FontBold, 'OFFLINE', r, 13, C_CRIT, haCenter);
  end;

  Txt(FontNum, FormatDateTime('hh:nn:ss', Plant.Clock), 1580, 6, 30, C_TEXT, haRight);
  Txt(FontUI, FormatDateTime('ddd d mmm yyyy', Plant.Clock) + '   ' + ShiftName(Plant.Clock), 1580, 40, 13, C_TEXT2, haRight);
end;

{ ---------------------------------------------------------------- overview }

procedure TFactoryHmi.DrawOverview;
begin
  DrawKpis(Rect(20, 76, 1560, 128));
  DrawProcessFlow(Rect(20, 218, 1560, 240));
  DrawStationTable(Rect(20, 472, 1010, 346));
  DrawStationDetail(Rect(1044, 472, 536, 346));
end;

procedure TFactoryHmi.DrawRing(const R: TRectangle; const Title, Sub: string; V, Target: Single);
var
  c: TVector2;
  a: Single;
begin
  Panel(R, C_PANEL, C_RIM);
  c := Vec2(R.x + 64, R.y + R.height / 2);
  raylib.DrawRing(c, 36, 46, -90, 270, 48, C_GRID);
  a := -90 + 360 * EnsureRange(V, 0, 1);
  if V > 0.001 then raylib.DrawRing(c, 36, 46, -90, a, 48, C_ACCENT);
  // target tick
  a := DegToRad(-90 + 360 * Target);
  DrawLineEx(Vec2(c.x + Cos(a) * 32, c.y + Sin(a) * 32), Vec2(c.x + Cos(a) * 50, c.y + Sin(a) * 50), 2, C_TEXT2);
  Txt(FontNum, Format('%.0f', [V * 100]), c.x, c.y - 15, 26, C_TEXT, haCenter);
  Txt(FontUI, '%', c.x, c.y + 9, 11, C_MUTED, haCenter);
  Txt(FontBold, Title, R.x + 124, R.y + 26, 17, C_TEXT);
  Txt(FontUI, Sub, R.x + 124, R.y + 50, 12, C_MUTED);
  Txt(FontUI, 'Target ' + Format('%.0f%%', [Target * 100]), R.x + 124, R.y + 84, 12, C_TEXT2);
end;

procedure TFactoryHmi.DrawKpis(const R: TRectangle);
var
  w, x: Single;
  t: TRectangle;
  good, expect, target: Int64;
  frac, mark: Single;
  diff: Int64;
begin
  w := (R.width - 5 * 14) / 6;
  x := R.x;
  DrawRing(Rect(x, R.y, w, R.height), 'OEE', 'Avail × Perf × Quality', Plant.OEE, 0.85);
  x := x + w + 14;
  DrawRing(Rect(x, R.y, w, R.height), 'Availability', 'Run time / planned', Plant.Availability, 0.90);
  x := x + w + 14;
  DrawRing(Rect(x, R.y, w, R.height), 'Performance', 'Actual / ideal rate', Plant.Performance, 0.95);
  x := x + w + 14;
  DrawRing(Rect(x, R.y, w, R.height), 'Quality', 'Good / total', Plant.Quality, 0.99);
  x := x + w + 14;

  // output vs plan
  t := Rect(x, R.y, w, R.height);
  Panel(t, C_PANEL, C_RIM);
  good := Plant.Good;
  expect := Plant.ExpectedByNow;
  target := Plant.ShiftTarget;
  Txt(FontBold, 'GOOD PARTS', t.x + 16, t.y + 12, 13, C_TEXT2);
  Txt(FontNum, IntToStr(good), t.x + 16, t.y + 30, 36, C_TEXT);
  Txt(FontUI, '/ ' + IntToStr(target) + ' shift', t.x + t.width - 16, t.y + 48, 12, C_MUTED, haRight);
  frac := EnsureRange(good / Max(1, target), 0, 1);
  mark := EnsureRange(expect / Max(1, target), 0, 1);
  DrawRectangleRounded(Rect(t.x + 16, t.y + 80, t.width - 32, 8), 1, 6, C_GRID);
  if frac > 0 then
    DrawRectangleRounded(Rect(t.x + 16, t.y + 80, (t.width - 32) * frac, 8), 1, 6, C_ACCENT);
  DrawRectangle(Round(t.x + 16 + (t.width - 32) * mark) - 1, Round(t.y + 76), 2, 16, C_TEXT);
  diff := good - expect;
  if diff >= 0 then
    Txt(FontUI, Format('Plan now %d   +%d ahead', [expect, diff]), t.x + 16, t.y + 98, 12, C_TEXT2)
  else
    Txt(FontUI, Format('Plan now %d   %d behind', [expect, -diff]), t.x + 16, t.y + 98, 12, C_TEXT2);
  x := x + w + 14;

  // rate + power
  t := Rect(x, R.y, w, R.height);
  Panel(t, C_PANEL, C_RIM);
  Txt(FontBold, 'OUTPUT RATE', t.x + 16, t.y + 12, 13, C_TEXT2);
  Txt(FontNum, Format('%.1f', [Plant.OutputRate]), t.x + 16, t.y + 28, 32, C_TEXT);
  Txt(FontUI, 'parts/min', t.x + 16 + TextWidth(FontNum, Format('%.1f', [Plant.OutputRate]), 32) + 8, t.y + 44, 12, C_MUTED);
  Txt(FontBold, 'POWER', t.x + 16, t.y + 72, 13, C_TEXT2);
  Txt(FontNum, Format('%.0f kW', [Plant.TotalPower]), t.x + 16, t.y + 88, 24, C_TEXT);
  Txt(FontBold, 'REJECTS', t.x + 140, t.y + 72, 13, C_TEXT2);
  Txt(FontNum, IntToStr(Plant.Rejected), t.x + 140, t.y + 88, 24, C_TEXT);
end;

procedure TFactoryHmi.DrawStationTile(i: Integer; const R: TRectangle);
var
  st: TStation;
  rim: TColor;
  over: Boolean;
  y: Single;
begin
  st := Plant.Stations[i];
  rim := C_RIM;
  if st.State = ssFault then rim := C_CRIT
  else if i = FSel then rim := C_ACCENT;
  Panel(R, C_PANEL_HI, rim, 0.1);
  if i = FSel then
    DrawRectangleRoundedLinesEx(Inset(R, -3), 0.1, 6, 2, C_ACCENT);
  if (st.State = ssFault) and Plant.Alarms.IsOpen(st.Code + '.FAULT') and FBlink then
    DrawRectangleRoundedLinesEx(Inset(R, -3), 0.1, 6, 3, C_CRIT);

  Txt(FontBold, st.Code, R.x + 14, R.y + 10, 13, C_MUTED);
  StateIcon(st.State, R.x + R.width - 22, R.y + 20, 16, False);
  Txt(FontBold, st.Name, R.x + 14, R.y + 28, 18, C_TEXT);
  Txt(FontBold, STATE_TEXT[st.State], R.x + 14, R.y + 54, 13, StateColor(st.State));

  y := R.y + 80;
  Txt(FontNum, Format('%.0f', [st.Speed]), R.x + 14, y, 24, C_TEXT);
  Txt(FontUI, Format('/min  SP %.0f', [st.SpeedSP]), R.x + 14 + TextWidth(FontNum, Format('%.0f', [st.Speed]), 24) + 6, y + 8, 12, C_MUTED);

  over := st.Temp > st.TempHi;
  y := R.y + 112;
  if over then AlarmIcon(apHigh, R.x + 22, y + 12, 16);
  Txt(FontNum, Format('%.0f °C', [st.Temp]), R.x + 14 + IfThen(over, 18, 0), y, 20, Pick(over, C_HIGH, C_TEXT2));
  Txt(FontNum, Format('%.1f mm/s', [st.Vib]), R.x + R.width - 14, y + 2, 16,
    Pick(st.Vib > st.VibHi, C_MED, C_TEXT2), haRight);

  if Clicked(R) then FSel := i;
  if Hover(R) then UiHand := True;
end;

procedure TFactoryHmi.DrawProcessFlow(const R: TRectangle);
var
  i, k, n: Integer;
  tw, gap, x0, x1, cy, sx, ph: Single;
  tiles: array[0..STATION_COUNT - 1] of TRectangle;
  moving: Boolean;
  s: string;
begin
  Panel(R, C_PANEL, C_RIM, 0.04);
  PanelTitle(R, 'LINE A  ·  PROCESS FLOW');
  if Plant.LineRunning then s := 'LINE RUNNING' else s := 'LINE STOPPED';
  Txt(FontBold, s, R.x + 230, R.y + 10, 15, Pick(Plant.LineRunning, C_RUN, C_STOP));
  if Button(Rect(R.x + R.width - 300, R.y + 8, 136, 32), 'START LINE', bsPrimary, not Plant.LineRunning) then
    Ask(caStartLine, -1, 'Start all stations of Assembly Line A?');
  if Button(Rect(R.x + R.width - 152, R.y + 8, 136, 32), 'STOP LINE', bsDanger, Plant.LineRunning) then
    Ask(caStopLine, -1, 'Stop Assembly Line A? Parts in the stations will stay where they are.');

  tw := 200;
  gap := (R.width - 32 - STATION_COUNT * tw) / (STATION_COUNT - 1);
  for i := 0 to STATION_COUNT - 1 do
    tiles[i] := Rect(R.x + 16 + i * (tw + gap), R.y + 56, tw, 166);

  // conveyors with buffer queues (parts waiting in front of the next station)
  for i := 0 to STATION_COUNT - 2 do
  begin
    x0 := tiles[i].x + tw + 6;
    x1 := tiles[i + 1].x - 6;
    cy := tiles[i].y + 83;
    DrawRectangle(Round(x0), Round(cy - 3), Round(x1 - x0), 6, C_GRID);
    moving := Plant.Stations[i].State = ssRunning;
    if moving then
    begin
      // chevrons flowing towards the next station
      ph := Frac(FTime * Plant.Stations[i].Speed / 60);
      for k := 0 to 3 do
      begin
        sx := x0 + ((k + ph) / 4) * (x1 - x0 - 8);
        DrawTriangle(Vec2(sx, cy - 6), Vec2(sx, cy + 6), Vec2(sx + 7, cy), Fade(C_ACCENT, 200));
      end;
    end;
    n := Plant.Stations[i + 1].InBuf;
    for k := 0 to Min(n, BUFFER_CAP) - 1 do
      DrawRectangle(Round(x1 - 6 - (k mod 6) * 9), Round(cy - 26 - (k div 6) * 9), 7, 7,
        Pick(n >= BUFFER_CAP, C_WAIT, C_TEXT2));
    Txt(FontUI, Format('%d/%d', [n, BUFFER_CAP]), (x0 + x1) / 2, cy + 10, 11, C_MUTED, haCenter);
  end;
  for i := 0 to STATION_COUNT - 1 do
    DrawStationTile(i, tiles[i]);
end;

procedure TFactoryHmi.DrawStationTable(const R: TRectangle);
const
  HEADS: array[0..7] of string = ('Station', 'State', 'Speed / SP', 'Temp °C', 'Vib mm/s', 'Power kW', 'Processed', 'Run %');
  COLX: array[0..7] of Single = (16, 196, 356, 486, 596, 706, 806, 916);
var
  i, c: Integer;
  y: Single;
  st: TStation;
  row: TRectangle;
  run: Single;
begin
  Panel(R, C_PANEL, C_RIM, 0.04);
  PanelTitle(R, 'STATIONS');
  for c := 0 to 7 do
    Txt(FontBold, HEADS[c], R.x + COLX[c], R.y + 42, 12, C_MUTED);
  DrawRectangle(Round(R.x + 12), Round(R.y + 62), Round(R.width - 24), 1, C_GRID);
  for i := 0 to STATION_COUNT - 1 do
  begin
    st := Plant.Stations[i];
    y := R.y + 70 + i * 44;
    row := Rect(R.x + 8, y, R.width - 16, 40);
    if i = FSel then DrawRectangleRounded(row, 0.2, 6, Fade(C_ACCENT_DIM, 170))
    else if Hover(row) then DrawRectangleRounded(row, 0.2, 6, Fade(C_ACCENT_DIM, 80));
    Txt(FontBold, st.Code, R.x + COLX[0], y + 11, 15, C_TEXT);
    Txt(FontUI, st.Name, R.x + COLX[0] + 50, y + 11, 15, C_TEXT2);
    StateIcon(st.State, R.x + COLX[1] + 7, y + 20, 13, False);
    Txt(FontBold, STATE_TEXT[st.State], R.x + COLX[1] + 22, y + 12, 13, StateColor(st.State));
    Txt(FontNum, Format('%.0f / %.0f', [st.Speed, st.SpeedSP]), R.x + COLX[2], y + 10, 17, C_TEXT);
    if st.Temp > st.TempHi then
    begin
      AlarmIcon(apHigh, R.x + COLX[3] + 7, y + 20, 13);
      Txt(FontNum, Format('%.1f', [st.Temp]), R.x + COLX[3] + 20, y + 10, 17, C_HIGH);
    end
    else
      Txt(FontNum, Format('%.1f', [st.Temp]), R.x + COLX[3], y + 10, 17, C_TEXT);
    if st.Vib > st.VibHi then
    begin
      AlarmIcon(apMedium, R.x + COLX[4] + 7, y + 20, 12);
      Txt(FontNum, Format('%.2f', [st.Vib]), R.x + COLX[4] + 20, y + 10, 17, C_MED);
    end
    else
      Txt(FontNum, Format('%.2f', [st.Vib]), R.x + COLX[4], y + 10, 17, C_TEXT);
    Txt(FontNum, Format('%.1f', [st.Power]), R.x + COLX[5], y + 10, 17, C_TEXT);
    Txt(FontNum, IntToStr(st.Processed), R.x + COLX[6], y + 10, 17, C_TEXT);
    if Plant.SimTime > 0 then run := st.RunTime / Plant.SimTime else run := 0;
    Txt(FontNum, Format('%.0f', [run * 100]), R.x + COLX[7], y + 10, 17, C_TEXT);
    if Clicked(row) then FSel := i;
    if Hover(row) then UiHand := True;
  end;
end;

procedure TFactoryHmi.DrawBar(const R: TRectangle; const L: string; V, MaxV, Hi, Trip: Single; const Units: string);
var
  bw, fx: Single;
  col: TColor;
begin
  Txt(FontBold, L, R.x, R.y, 12, C_MUTED);
  if (Trip > 0) and (V > Hi) then col := C_HIGH else col := C_ACCENT;
  Txt(FontNum, Format('%.1f %s', [V, Units]), R.x + R.width, R.y - 2, 15, Pick(V > Hi, C_HIGH, C_TEXT), haRight);
  bw := R.width;
  DrawRectangleRounded(Rect(R.x, R.y + 22, bw, 10), 1, 6, C_GRID);
  fx := EnsureRange(V / MaxV, 0, 1);
  if fx > 0 then DrawRectangleRounded(Rect(R.x, R.y + 22, bw * fx, 10), 1, 6, col);
  // limit marks
  DrawRectangle(Round(R.x + bw * Hi / MaxV), Round(R.y + 18), 2, 18, C_HIGH);
  if Trip > 0 then DrawRectangle(Round(R.x + bw * Trip / MaxV), Round(R.y + 18), 2, 18, C_CRIT);
end;

procedure TFactoryHmi.DrawStationDetail(const R: TRectangle);
var
  st: TStation;
  y: Single;
  box: TRectangle;
  i: Integer;
begin
  i := FSel;
  st := Plant.Stations[i];
  Panel(R, C_PANEL, C_RIM, 0.04);
  PanelTitle(R, 'STATION DETAIL');
  Txt(FontBold, st.Code + '  ·  ' + st.Name, R.x + 16, R.y + 36, 22, C_TEXT);
  StateIcon(st.State, R.x + 28, R.y + 82, 20, False);
  Txt(FontBold, STATE_TEXT[st.State], R.x + 46, R.y + 70, 20, StateColor(st.State));
  Txt(FontUI, Format('for %.0f s', [Plant.SimTime - st.StateSince]), R.x + 46 + TextWidth(FontBold, STATE_TEXT[st.State], 20) + 10, R.y + 76, 13, C_MUTED);

  y := R.y + 104;
  if st.State = ssFault then
  begin
    box := Rect(R.x + 16, y, R.width - 32, 40);
    DrawRectangleRounded(box, 0.2, 6, ColorRGBA(70, 22, 26, 230));
    AlarmIcon(apCritical, box.x + 20, box.y + 20, 20);
    TxtIn(FontBold, st.FaultText, Rect(box.x + 38, box.y, box.width - 40, box.height), 15, C_TEXT, haLeft);
  end
  else if st.State = ssMaint then
  begin
    box := Rect(R.x + 16, y, R.width - 32, 40);
    DrawRectangleRounded(box, 0.2, 6, Fade(C_MAINT, 60));
    TxtIn(FontBold, Pick2(Plant.Live, 'Maintenance in progress',
      Format('Technician on site  ·  ready in %.0f s', [Max(0, st.RepairAt - Plant.SimTime)])),
      Rect(box.x + 14, box.y, box.width, box.height), 15, C_TEXT, haLeft);
  end
  else if st.State in [ssStarved, ssBlocked] then
  begin
    if st.State = ssStarved then
      Txt(FontUI, 'Waiting for parts from the previous station', R.x + 16, y + 10, 14, C_TEXT2)
    else
      Txt(FontUI, 'Output buffer full - next station is not taking parts', R.x + 16, y + 10, 14, C_TEXT2);
  end;

  y := R.y + 156;
  if Button(Rect(R.x + 16, y, 120, 38), 'START', bsPrimary, (not st.Enabled) and (st.State in [ssStopped]) ) then
    Ask(caStartStation, i, Format('Start %s %s?', [st.Code, st.Name]));
  if Button(Rect(R.x + 146, y, 120, 38), 'STOP', bsDanger, st.Enabled and (st.State <> ssFault)) then
    Ask(caStopStation, i, Format('Stop %s %s? The line will starve after it.', [st.Code, st.Name]));
  if Button(Rect(R.x + 276, y, 120, 38), 'RESET', bsNormal, st.State = ssFault) then
    Plant.ResetStation(i);

  // speed setpoint
  Txt(FontBold, 'SPEED SETPOINT', R.x + 16, y + 52, 12, C_MUTED);
  if Button(Rect(R.x + 16, y + 70, 52, 36), '- 5') then Plant.SetSpeed(i, st.SpeedSP - 5);
  box := Rect(R.x + 74, y + 70, 120, 36);
  DrawRectangleRounded(box, 0.25, 6, C_BG);
  TxtIn(FontNum, Format('%.0f /min', [st.SpeedSP]), box, 20, C_TEXT, haCenter);
  if Button(Rect(R.x + 200, y + 70, 52, 36), '+ 5') then Plant.SetSpeed(i, st.SpeedSP + 5);
  Txt(FontUI, Format('max %.0f', [st.SpeedMax]), R.x + 262, y + 80, 12, C_MUTED);

  DrawBar(Rect(R.x + 16, y + 118, R.width - 32, 40), 'TEMPERATURE', st.Temp, st.TempTrip + 15, st.TempHi, st.TempTrip, '°C');
  DrawBar(Rect(R.x + 16, y + 154, R.width - 32, 40), 'VIBRATION', st.Vib, 10, st.VibHi, 0, 'mm/s');
  Txt(FontUI, Format('Processed %d  ·  Rejects %d  ·  %.1f kW', [st.Processed, st.Rejects, st.Power]),
    R.x + R.width - 16, R.y + 12, 13, C_TEXT2, haRight);
end;

{ ---------------------------------------------------------------- trends }

procedure TFactoryHmi.DrawChart(T: TTrend; const R: TRectangle);
var
  pr: TRectangle;
  i, n, k: Integer;
  v, x, y, px, py, frac: Single;
  above, pabove: Boolean;
  col: TColor;
  s: string;

  function YOf(val: Single): Single;
  begin
    Result := pr.y + pr.height - (EnsureRange(val, T.MinV, T.MaxV) - T.MinV) / (T.MaxV - T.MinV) * pr.height;
  end;

  procedure Dashed(yy: Single; c: TColor);
  var
    xx: Single;
  begin
    xx := pr.x;
    while xx < pr.x + pr.width do
    begin
      DrawLineEx(Vec2(xx, yy), Vec2(Min(xx + 8, pr.x + pr.width), yy), 1.5, c);
      xx := xx + 14;
    end;
  end;

begin
  Panel(R, C_PANEL, C_RIM, 0.04);
  Txt(FontBold, UpperCase(T.Name), R.x + 16, R.y + 12, 14, C_TEXT2);
  v := T.Last;
  above := (T.HiLimit > 0) and (v > T.HiLimit);
  if above then AlarmIcon(apHigh, R.x + R.width - 200, R.y + 26, 18);
  Txt(FontNum, Format('%.1f', [v]), R.x + R.width - 80, R.y + 8, 30, Pick(above, C_HIGH, C_TEXT), haRight);
  Txt(FontUI, T.Units, R.x + R.width - 72, R.y + 22, 13, C_MUTED);

  pr := Rect(R.x + 60, R.y + 56, R.width - 84, R.height - 92);
  for k := 0 to 4 do
  begin
    y := pr.y + pr.height * k / 4;
    DrawRectangle(Round(pr.x), Round(y), Round(pr.width), 1, Fade(C_GRID, 140));
    Txt(FontNum, Format('%.0f', [T.MaxV - (T.MaxV - T.MinV) * k / 4]), pr.x - 10, y - 8, 13, C_MUTED, haRight);
  end;
  for k := 0 to 4 do
  begin
    x := pr.x + pr.width * k / 4;
    if k < 4 then s := Format('-%d s', [120 - k * 30]) else s := 'now';
    Txt(FontUI, s, x, pr.y + pr.height + 8, 12, C_MUTED, haCenter);
  end;
  if T.HiLimit > 0 then
  begin
    Dashed(YOf(T.HiLimit), C_HIGH);
    Txt(FontBold, Format('HI %.0f', [T.HiLimit]), pr.x + 6, YOf(T.HiLimit) - 18, 12, C_HIGH);
  end;
  if T.LoLimit > 0 then
  begin
    Dashed(YOf(T.LoLimit), C_MED);
    Txt(FontBold, Format('LO %.0f', [T.LoLimit]), pr.x + 6, YOf(T.LoLimit) + 4, 12, C_MED);
  end;

  n := T.Count;
  px := 0; py := 0; pabove := False;
  for i := 0 to n - 1 do
  begin
    v := T.Get(i);
    x := pr.x + pr.width * (TREND_CAP - n + i) / (TREND_CAP - 1);
    y := YOf(v);
    above := ((T.HiLimit > 0) and (v > T.HiLimit)) or ((T.LoLimit > 0) and (v < T.LoLimit));
    if i > 0 then
    begin
      if above or pabove then col := C_HIGH else col := C_ACCENT;
      DrawLineEx(Vec2(px, py), Vec2(x, y), 2, col);
    end;
    px := x; py := y; pabove := above;
  end;

  // hover read-out
  if Hover(pr) and (n > 1) then
  begin
    frac := (UiMouse.x - pr.x) / pr.width;
    i := Round(frac * (TREND_CAP - 1)) - (TREND_CAP - n);
    if (i >= 0) and (i < n) then
    begin
      v := T.Get(i);
      x := pr.x + pr.width * (TREND_CAP - n + i) / (TREND_CAP - 1);
      DrawRectangle(Round(x), Round(pr.y), 1, Round(pr.height), C_TEXT2);
      DrawCircle(Round(x), Round(YOf(v)), 5, C_TEXT);
      s := Format('%.1f %s   %.1f s ago', [v, T.Units, (n - 1 - i) / TREND_HZ]);
      DrawRectangleRounded(Rect(x + 10, YOf(v) - 34, TextWidth(FontUI, s, 14) + 20, 28), 0.3, 6, C_BG);
      Txt(FontUI, s, x + 20, YOf(v) - 28, 14, C_TEXT);
    end;
  end;
end;

procedure TFactoryHmi.DrawTrends;
var
  w, h: Single;
  i: Integer;
begin
  w := (1560 - 16) / 2;
  h := (742 - 16) / 2;
  for i := 0 to 3 do
    DrawChart(Plant.Trends[i], Rect(20 + (i mod 2) * (w + 16), 76 + (i div 2) * (h + 16), w, h));
end;

{ ---------------------------------------------------------------- alarms }

procedure TFactoryHmi.DrawAlarms;
const
  COLX: array[0..5] of Single = (20, 56, 156, 266, 346, 1170);
  HEADS: array[0..5] of string = ('', 'Time', 'Priority', 'Station', 'Message', 'State');
  ROW_H = 38;
var
  R, list, row: TRectangle;
  idx: array of Integer;
  n, i, j, tmp, total, first, last: Integer;
  a: TAlarm;
  y, maxScroll: Single;
  views: array[0..2] of string;
  unackRow: Boolean;
  bg: TColor;

  function Before(x, y2: Integer): Boolean;
  var
    ax, ay: TAlarm;
    ux, uy: Boolean;
  begin
    // active view: unacknowledged first, then priority, then newest
    ax := Plant.Alarms.Get(x); ay := Plant.Alarms.Get(y2);
    ux := ax.State in [asActiveUnack, asClearedUnack];
    uy := ay.State in [asActiveUnack, asClearedUnack];
    if ux <> uy then Exit(ux);
    if ax.Priority <> ay.Priority then Exit(ax.Priority < ay.Priority);
    Result := ax.RaisedAt > ay.RaisedAt;
  end;

begin
  R := Rect(20, 76, 1560, 742);
  Panel(R, C_PANEL, C_RIM, 0.02);

  views[0] := Format('Active (%d)', [Plant.Alarms.OpenCount]);
  views[1] := Format('History (%d)', [Plant.Alarms.Count]);
  views[2] := Format('Event log (%d)', [Plant.Events.Count]);
  for i := 0 to 2 do
    if Tab(Rect(R.x + 14 + i * 176, R.y + 10, 168, 44), views[i], '', Ord(FAlarmView) = i, 0, C_CRIT) then
    begin
      FAlarmView := TAlarmView(i);
      FAlarmScroll := 0;
    end;
  if Button(Rect(R.x + R.width - 520, R.y + 14, 160, 36), 'ACK SELECTED', bsPrimary,
    (FAlarmSel >= 0) and (FAlarmView <> avEvents)) then
    Plant.Alarms.Ack(FAlarmSel);
  if Button(Rect(R.x + R.width - 350, R.y + 14, 150, 36), 'ACK ALL', bsPrimary, Plant.Alarms.UnackCount > 0) then
    Plant.Alarms.AckAll;
  if Button(Rect(R.x + R.width - 190, R.y + 14, 176, 36), 'EXPORT REPORT') then
    ExportReport;

  // build the row list
  n := 0;
  SetLength(idx, Plant.Alarms.Count);
  if FAlarmView = avActive then
  begin
    for i := 0 to Plant.Alarms.Count - 1 do
      if Plant.Alarms.Get(i).State <> asCleared then begin idx[n] := i; Inc(n); end;
    for i := 1 to n - 1 do
    begin
      tmp := idx[i]; j := i - 1;
      while (j >= 0) and Before(tmp, idx[j]) do begin idx[j + 1] := idx[j]; Dec(j); end;
      idx[j + 1] := tmp;
    end;
  end
  else if FAlarmView = avHistory then
    for i := Plant.Alarms.Count - 1 downto 0 do begin idx[n] := i; Inc(n); end;
  if FAlarmView = avEvents then total := Plant.Events.Count else total := n;

  // header
  if FAlarmView <> avEvents then
    for i := 1 to 5 do
      Txt(FontBold, HEADS[i], R.x + COLX[i], R.y + 70, 12, C_MUTED);
  DrawRectangle(Round(R.x + 12), Round(R.y + 90), Round(R.width - 24), 1, C_GRID);

  list := Rect(R.x + 8, R.y + 96, R.width - 16, R.height - 104);
  if Hover(list) then FAlarmScroll := FAlarmScroll - GetMouseWheelMove * ROW_H * 3;
  maxScroll := Max(0, total * ROW_H - list.height);
  FAlarmScroll := EnsureRange(FAlarmScroll, 0, maxScroll);

  if total = 0 then
  begin
    TxtIn(FontUI, 'No alarms', list, 18, C_MUTED, haCenter);
    Exit;
  end;

  ScissorDesign(list);   // scissor is in target pixels; the camera stays active
  first := Trunc(FAlarmScroll / ROW_H);
  last := Min(total - 1, first + Trunc(list.height / ROW_H) + 1);
  for j := first to last do
  begin
    y := list.y + j * ROW_H - FAlarmScroll;
    row := Rect(list.x, y, list.width, ROW_H - 2);
    if FAlarmView = avEvents then
    begin
      if j mod 2 = 0 then DrawRectangleRounded(row, 0.15, 6, Fade(C_PANEL_HI, 120));
      Txt(FontUI, Plant.Events[Plant.Events.Count - 1 - j], row.x + 12, y + 9, 15, C_TEXT2);
      Continue;
    end;
    a := Plant.Alarms.Get(idx[j]);
    unackRow := a.State in [asActiveUnack, asClearedUnack];
    bg := Fade(C_PANEL_HI, 110);
    if unackRow then bg := Fade(PriorityColor(a.Priority), 34);
    if a.Id = FAlarmSel then bg := Fade(C_ACCENT_DIM, 230);
    DrawRectangleRounded(row, 0.15, 6, bg);
    if not (unackRow and (a.State = asActiveUnack) and FBlink) then
      AlarmIcon(a.Priority, row.x + COLX[0] + 8, y + ROW_H / 2 - 1, 18);
    Txt(FontNum, FormatDateTime('hh:nn:ss', a.RaisedAt), R.x + COLX[1], y + 9, 16, C_TEXT);
    Txt(FontBold, PRIORITY_NAME[a.Priority], R.x + COLX[2], y + 10, 13, PriorityColor(a.Priority));
    Txt(FontBold, a.Station, R.x + COLX[3], y + 10, 14, C_TEXT);
    Txt(FontUI, a.Text, R.x + COLX[4], y + 9, 15, Pick(a.State = asCleared, C_MUTED, C_TEXT));
    Txt(FontBold, STATE_NAME[a.State], R.x + COLX[5], y + 10, 13,
      Pick(unackRow, C_TEXT, C_MUTED));
    if Clicked(row) then
      if FAlarmSel = a.Id then FAlarmSel := -1 else FAlarmSel := a.Id;
    if Hover(row) then UiHand := True;
  end;
  EndScissorMode;
  if maxScroll > 0 then
    DrawRectangleRounded(Rect(list.x + list.width - 6, list.y + list.height * FAlarmScroll / (total * ROW_H),
      4, list.height * list.height / (total * ROW_H)), 1, 4, C_RIM);
end;

{ ---------------------------------------------------------------- banner / dialogs }

procedure TFactoryHmi.DrawBanner;
var
  R, ack: TRectangle;
  k: Integer;
  a: TAlarm;
  x: Single;
  p: TAlarmPriority;
begin
  R := Rect(20, 832, 1560, 56);
  k := Plant.Alarms.TopUnack;
  if k < 0 then k := Plant.Alarms.TopOpen;
  if k < 0 then
  begin
    Panel(R, C_PANEL, C_RIM, 0.2);
    DrawCircle(Round(R.x + 30), Round(R.y + 28), 8, C_RUN);
    TxtIn(FontBold, 'No active alarms', Rect(R.x + 50, R.y, 400, R.height), 17, C_TEXT2);
  end
  else
  begin
    a := Plant.Alarms.Get(k);
    if a.State in [asActiveUnack, asClearedUnack] then
      Panel(R, Mix(C_PANEL, PriorityColor(a.Priority), 0.22), PriorityColor(a.Priority), 0.2)
    else
      Panel(R, C_PANEL, C_RIM, 0.2);
    if not ((a.State = asActiveUnack) and FBlink) then
      AlarmIcon(a.Priority, R.x + 30, R.y + 28, 26);
    Txt(FontNum, FormatDateTime('hh:nn:ss', a.RaisedAt), R.x + 56, R.y + 15, 20, C_TEXT);
    Txt(FontBold, PRIORITY_NAME[a.Priority], R.x + 150, R.y + 18, 14, PriorityColor(a.Priority));
    Txt(FontBold, a.Station, R.x + 250, R.y + 16, 17, C_TEXT);
    Txt(FontUI, a.Text, R.x + 320, R.y + 16, 17, C_TEXT);
    if a.State in [asActiveUnack, asClearedUnack] then
    begin
      ack := Rect(R.x + R.width - 300, R.y + 10, 100, 36);
      if Button(ack, 'ACK', bsPrimary) then Plant.Alarms.Ack(a.Id);
    end;
  end;
  // counts per priority (shape + number, readable without colour)
  x := R.x + R.width - 180;
  for p := Low(TAlarmPriority) to High(TAlarmPriority) do
  begin
    AlarmIcon(p, x, R.y + 28, 18);
    Txt(FontNum, IntToStr(Plant.Alarms.OpenCountOf(p)), x + 14, R.y + 16, 20, C_TEXT);
    x := x + 50;
  end;
  if (k >= 0) and (Screen <> scAlarms) and Clicked(Rect(R.x, R.y, R.width - 310, R.height)) then
    Screen := scAlarms;
end;

procedure TFactoryHmi.DrawConfirm;
var
  R: TRectangle;
  danger: Boolean;
  style: TButtonStyle;
begin
  DrawRectangle(0, 0, DESIGN_W, DESIGN_H, ColorRGBA(0, 0, 0, 150));
  R := Rect(DESIGN_W / 2 - 290, DESIGN_H / 2 - 120, 580, 240);
  danger := FConfirm in [caStopLine, caStopStation];
  Panel(R, C_PANEL_HI, Pick(danger, C_CRIT, C_ACCENT), 0.06);
  Txt(FontBold, 'CONFIRM COMMAND', R.x + 24, R.y + 20, 15, C_TEXT2);
  Txt(FontBold, FConfirmText, R.x + 24, R.y + 64, 19, C_TEXT);
  Txt(FontUI, 'Esc or Cancel to go back', R.x + 24, R.y + 100, 13, C_MUTED);
  if Button(Rect(R.x + 24, R.y + 168, 200, 46), 'CANCEL', bsNormal, True, 1) then
    FConfirm := caNone;
  if danger then style := bsDanger else style := bsPrimary;
  if Button(Rect(R.x + R.width - 224, R.y + 168, 200, 46), Pick2(danger, 'STOP', 'START'), style, True, 1) then
    DoConfirmed;
end;

procedure TFactoryHmi.DrawToast;
var
  R: TRectangle;
  w: Single;
begin
  if (FToast = '') or (FTime > FToastUntil) then Exit;
  w := TextWidth(FontUI, FToast, 15) + 40;
  R := Rect(DESIGN_W / 2 - w / 2, 74, w, 36);
  Panel(R, C_PANEL_HI, C_ACCENT, 0.4);
  TxtIn(FontUI, FToast, R, 15, C_TEXT, haCenter);
end;

end.
