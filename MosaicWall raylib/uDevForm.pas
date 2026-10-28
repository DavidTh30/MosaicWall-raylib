unit uDevForm;

{ Developer status window for MosaicWall.

  raylib can only own one window per process, so this is a normal LCL form and the
  mosaic runs in its own raylib window next to it, on a dedicated render thread
  (TRenderThread: InitWindow, the frame loop and CloseWindow all happen there).

  Why a thread: with both on the main thread, raylib's event polling ran this form's
  repaints inside a frame, and every 250 ms refresh made the animation miss a vsync.

  The form never calls raylib. It reads engine state between Engine.Lock/Unlock and changes
  it with Engine.Post(); the engine runs posted commands at the start of the next frame. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, ComCtrls, Spin,
  uMosaicEngine, uMosaicReport;

type
  TStatusRow = record
    Caption, Value: string;
  end;
  TStatusRows = array of TStatusRow;

  { TDevForm }

  TDevForm = class(TForm)
    btnApplySeed: TButton;
    btnExpAll: TButton;
    btnExpCsv: TButton;
    btnExpJson: TButton;
    btnExpRender: TButton;
    btnExpShot: TButton;
    btnExpTxt: TButton;
    btnFullscreen: TButton;
    btnOpenFolder: TButton;
    btnReseed: TButton;
    cbAnimate: TCheckBox;
    cbDim: TCheckBox;
    cbGlow: TComboBox;
    cbHud: TCheckBox;
    cbRes: TComboBox;
    cbScroll: TCheckBox;
    cbVignette: TCheckBox;
    cbWinSize: TComboBox;
    gbExport: TGroupBox;
    gbScene: TGroupBox;
    lblCell: TLabel;
    lblCpu: TLabel;
    lblDraw: TLabel;
    lblFolder: TLabel;
    lblFps: TLabel;
    lblFrame: TLabel;
    lblGlow: TLabel;
    lblMotion: TLabel;
    lblRes: TLabel;
    lblSeed: TLabel;
    lblState: TLabel;
    lblWin: TLabel;
    lvStatus: TListView;
    memLog: TMemo;
    pbGraph: TPaintBox;
    pnlFps: TPanel;
    pnlMain: TPanel;
    pnlRight: TPanel;
    pnlTop: TPanel;
    sbMain: TStatusBar;
    seSeed: TSpinEdit;
    splLog: TSplitter;
    tbCell: TTrackBar;
    tbMotion: TTrackBar;
    tmrRefresh: TTimer;
    procedure btnApplySeedClick(Sender: TObject);
    procedure btnExpAllClick(Sender: TObject);
    procedure btnExpCsvClick(Sender: TObject);
    procedure btnExpJsonClick(Sender: TObject);
    procedure btnExpRenderClick(Sender: TObject);
    procedure btnExpShotClick(Sender: TObject);
    procedure btnExpTxtClick(Sender: TObject);
    procedure btnFullscreenClick(Sender: TObject);
    procedure btnOpenFolderClick(Sender: TObject);
    procedure btnReseedClick(Sender: TObject);
    procedure cbAnimateChange(Sender: TObject);
    procedure cbDimChange(Sender: TObject);
    procedure cbGlowChange(Sender: TObject);
    procedure cbHudChange(Sender: TObject);
    procedure cbScrollChange(Sender: TObject);
    procedure cbVignetteChange(Sender: TObject);
    procedure cbWinSizeChange(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure lvStatusData(Sender: TObject; Item: TListItem);
    procedure lvStatusResize(Sender: TObject);
    procedure lvStatusCustomDrawItem(Sender: TCustomListView; Item: TListItem;
      State: TCustomDrawState; var DefaultDraw: Boolean);
    procedure pbGraphPaint(Sender: TObject);
    procedure tbCellChange(Sender: TObject);
    procedure tbMotionChange(Sender: TObject);
    procedure tmrRefreshTimer(Sender: TObject);
  private
    FEngine: TMosaicEngine;
    FRows: TStatusRows;       // data behind the virtual status list
    FUpdating: Boolean;       // true while controls are synced from the engine (ignore OnChange)
    FShownEvents: Int64;
    FClosing: Boolean;
    FTicks: Integer;
    FSelfTest: Boolean;       // --selftest: press "Export all" after 4 s, close after 7 s
    FThread: TThread;         // render thread that owns the raylib window
    procedure WindowClosed;   // queued by the render thread when the mosaic window closes
    procedure StopThread;
    procedure RefreshStatus;
    procedure SyncControls;
    procedure AppendEvents;
    procedure ExportCsv;
    function ParseSize(const S: string; out W, H: Integer): Boolean;
  public
    procedure StartEngine;
    property Engine: TMosaicEngine read FEngine;
  end;

var
  DevForm: TDevForm;

implementation

{$R *.lfm}

uses
  Windows, LCLIntf, uMosaicTypes, uMosaicStats;

function NowMs: Double;
var
  c, f: Int64;
begin
  QueryPerformanceCounter(c);
  QueryPerformanceFrequency(f);
  Result := c * 1000 / f;
end;

const
  SECTION_MARK = '■ ';

type
  TRenderThread = class(TThread)
  private
    FEngine: TMosaicEngine;
    FX, FY: Integer;
    FOnWindowClosed: TThreadMethod;
  protected
    procedure Execute; override;
  public
    constructor Create(AEngine: TMosaicEngine; AX, AY: Integer; AOnWindowClosed: TThreadMethod);
  end;

constructor TRenderThread.Create(AEngine: TMosaicEngine; AX, AY: Integer;
  AOnWindowClosed: TThreadMethod);
begin
  FEngine := AEngine;
  FX := AX;
  FY := AY;
  FOnWindowClosed := AOnWindowClosed;
  inherited Create(False);
end;

procedure TRenderThread.Execute;
begin
  try
    try
      FEngine.Open(540, 960, False, 'Mosaic Wallpaper');
      FEngine.MoveWindow(FX, FY);
      while not Terminated do
        if not FEngine.Frame then Break;
    finally
      FEngine.Close;   // same thread as InitWindow (GLFW requirement)
    end;
  except
    on E: Exception do
      FEngine.Log('RENDER THREAD ERROR: ' + E.Message);
  end;
  if not Terminated then Queue(FOnWindowClosed);
end;

{ TDevForm }

procedure TDevForm.FormCreate(Sender: TObject);
begin
  FEngine := TMosaicEngine.Create;
  lblFolder.Caption := FEngine.ExportDir;
  FSelfTest := Application.HasOption('selftest');
end;

procedure TDevForm.FormDestroy(Sender: TObject);
begin
  StopThread;
  FreeAndNil(FEngine);
end;

procedure TDevForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  FClosing := True;
  tmrRefresh.Enabled := False;
  StopThread;
end;

procedure TDevForm.StartEngine;
begin
  lvStatusResize(nil);
  // put the mosaic window just right of this form
  FThread := TRenderThread.Create(FEngine, Left + Width + 24, Top + 30, @WindowClosed);
end;

procedure TDevForm.StopThread;
begin
  if FThread = nil then Exit;
  FThread.Terminate;
  FThread.WaitFor;            // the thread closes the raylib window before it ends
  TThread.RemoveQueuedEvents(FThread);
  FreeAndNil(FThread);
end;

procedure TDevForm.WindowClosed;
begin
  // mosaic window closed (X or Esc) -> close the whole tool
  if not FClosing then Close;
end;

function TDevForm.ParseSize(const S: string; out W, H: Integer): Boolean;
var
  p: Integer;
begin
  p := Pos('x', LowerCase(S));
  W := StrToIntDef(Copy(S, 1, p - 1), 0);
  H := StrToIntDef(Copy(S, p + 1, MaxInt), 0);
  Result := (p > 0) and (W > 0) and (H > 0);
end;

{ ---- periodic refresh ---- }

procedure SetCaption(L: TLabel; const S: string);
begin
  if L.Caption <> S then L.Caption := S;
end;


procedure TDevForm.tmrRefreshTimer(Sender: TObject);
var
  S: TFrameSummary;
  t0: Double;
  c: TColor;
  txt: string;
begin
  if FEngine = nil then Exit;
  Inc(FTicks);
  if FSelfTest then
    if FTicks = 16 then btnExpAllClick(nil)
    else if FTicks = 28 then begin Close; Exit; end;

  t0 := NowMs;
  FEngine.Lock;
  try
    if not FEngine.Opened then Exit;
    S := FEngine.Stats.Summary;
    SetCaption(lblFps, Format('%.0f FPS', [S.Fps]));
    SetCaption(lblFrame, Format('frame %.2f ms (p99 %.2f)', [S.AvgMs, S.P99Ms]));
    SetCaption(lblCpu, Format('cpu %.2f ms (max %.2f)', [S.CpuAvgMs, S.CpuMaxMs]));
    SetCaption(lblDraw, Format('draw calls %d', [FEngine.DrawCalls]));
    SetCaption(lblState, FEngine.StateText);
    if S.Fps >= 55 then c := clGreen
    else if S.Fps >= 30 then c := $0080FF
    else c := clRed;
    if lblFps.Font.Color <> c then lblFps.Font.Color := c;

    RefreshStatus;
    SyncControls;
    AppendEvents;
    txt := Format('seed %d  |  %dx%d  |  %s  |  last export: %s',
      [FEngine.Cfg.Seed, FEngine.Width, FEngine.Height, FEngine.StateText,
       ExtractFileName(FEngine.LastExport)]);
    // shown in the status list next refresh, so the cost of this window is visible too
    FEngine.UiRefreshMs := NowMs - t0;
  finally
    FEngine.Unlock;
  end;
  if sbMain.SimpleText <> txt then sbMain.SimpleText := txt;
  pbGraph.Invalidate;
end;

procedure TDevForm.RefreshStatus;
var
  L: TStatusList;
  rows: TStatusRows;
  i, n: Integer;
  sec: string;
  r: TRect;
begin
  CollectStatus(FEngine, L);
  // flatten into rows, with a header row per section
  SetLength(rows, Length(L) * 2);
  n := 0;
  sec := '';
  for i := 0 to High(L) do
  begin
    if L[i].Section <> sec then
    begin
      sec := L[i].Section;
      rows[n].Caption := SECTION_MARK + sec;
      rows[n].Value := '';
      Inc(n);
    end;
    rows[n].Caption := '   ' + L[i].Key;
    rows[n].Value := L[i].Value;
    Inc(n);
  end;
  SetLength(rows, n);

  // virtual list (OwnerData): the control asks OnData for text, so a refresh is just
  // swapping the data and repainting the rows whose text changed
  if Length(FRows) <> n then
  begin
    FRows := rows;
    lvStatus.Items.Count := n;
    lvStatus.Invalidate;
    Exit;
  end;
  for i := 0 to n - 1 do
    if (FRows[i].Caption <> rows[i].Caption) or (FRows[i].Value <> rows[i].Value) then
    begin
      FRows[i] := rows[i];
      if lvStatus.HandleAllocated then
      begin
        r := lvStatus.Items[i].DisplayRect(drBounds);
        if (r.Bottom > 0) and (r.Top < lvStatus.ClientHeight) then
          InvalidateRect(lvStatus.Handle, @r, False);
      end;
    end;
end;

procedure TDevForm.lvStatusResize(Sender: TObject);
var
  w: Integer;
begin
  // Value column fills the rest (AutoSize does not work in OwnerData mode)
  w := lvStatus.ClientWidth - lvStatus.Columns[0].Width - GetSystemMetrics(SM_CXVSCROLL) - 4;
  if w < 80 then w := 80;
  if lvStatus.Columns[1].Width <> w then lvStatus.Columns[1].Width := w;
end;

procedure TDevForm.lvStatusData(Sender: TObject; Item: TListItem);
begin
  if (Item.Index < 0) or (Item.Index > High(FRows)) then Exit;
  Item.Caption := FRows[Item.Index].Caption;
  Item.SubItems.Add(FRows[Item.Index].Value);
end;

procedure TDevForm.SyncControls;
var
  i: Integer;
  ws: string;
begin
  FUpdating := True;
  try
    // assign only on change: every assignment to a native control costs a repaint
    if (not seSeed.Focused) and (seSeed.Value <> Integer(FEngine.Cfg.Seed)) then
      seSeed.Value := FEngine.Cfg.Seed;
    i := Round(FEngine.Cfg.CellRatio * 1000);
    if (not tbCell.Focused) and (tbCell.Position <> i) then tbCell.Position := i;
    ws := Format('Cell size ratio: %.3f  (%.0f px)', [FEngine.Cfg.CellRatio, FEngine.Mosaic.Cell]);
    if lblCell.Caption <> ws then lblCell.Caption := ws;
    i := Round(FEngine.Cfg.Motion * 100);
    if (not tbMotion.Focused) and (tbMotion.Position <> i) then tbMotion.Position := i;
    ws := Format('Motion: %d %%   ( [ ] )', [i]);
    if lblMotion.Caption <> ws then lblMotion.Caption := ws;
    if cbGlow.ItemIndex <> FEngine.Cfg.GlowMode then cbGlow.ItemIndex := FEngine.Cfg.GlowMode;
    if cbAnimate.Checked = FEngine.Paused then cbAnimate.Checked := not FEngine.Paused;
    if cbScroll.Checked <> FEngine.Cfg.GradientScroll then cbScroll.Checked := FEngine.Cfg.GradientScroll;
    if cbVignette.Checked <> (FEngine.Cfg.Vignette > 0) then cbVignette.Checked := FEngine.Cfg.Vignette > 0;
    if cbDim.Checked <> FEngine.Cfg.Dim then cbDim.Checked := FEngine.Cfg.Dim;
    if cbHud.Checked <> FEngine.ShowHud then cbHud.Checked := FEngine.ShowHud;
    ws := Format('%dx%d', [FEngine.Width, FEngine.Height]);
    i := cbWinSize.Items.IndexOf(ws);
    if i < 0 then
      i := cbWinSize.Items.Add(ws);   // custom size from dragging the window edge
    if (not cbWinSize.DroppedDown) and (cbWinSize.ItemIndex <> i) then cbWinSize.ItemIndex := i;
  finally
    FUpdating := False;
  end;
end;

procedure TDevForm.AppendEvents;
var
  first, i: Int64;
begin
  if FEngine.Stats.EventsTotal = FShownEvents then Exit;
  // Events keeps only the newest EVENTS_CAP lines; index of the first one kept:
  first := FEngine.Stats.EventsTotal - FEngine.Stats.Events.Count;
  if FShownEvents < first then FShownEvents := first;
  memLog.Lines.BeginUpdate;
  try
    for i := FShownEvents to FEngine.Stats.EventsTotal - 1 do
      memLog.Lines.Add(FEngine.Stats.Events[i - first]);
    while memLog.Lines.Count > EVENTS_CAP do
      memLog.Lines.Delete(0);
  finally
    memLog.Lines.EndUpdate;
  end;
  FShownEvents := FEngine.Stats.EventsTotal;
  memLog.SelStart := Length(memLog.Text);
end;

procedure TDevForm.lvStatusCustomDrawItem(Sender: TCustomListView; Item: TListItem;
  State: TCustomDrawState; var DefaultDraw: Boolean);
begin
  if Copy(Item.Caption, 1, Length(SECTION_MARK)) = SECTION_MARK then
  begin
    Sender.Canvas.Font.Style := [fsBold];
    Sender.Canvas.Brush.Color := $00F0E6DC;
  end
  else
    Sender.Canvas.Font.Style := [];
  DefaultDraw := True;
end;

procedure TDevForm.pbGraphPaint(Sender: TObject);
var
  c: TCanvas;
  W, H, n, i, x, y: Integer;
  f, cpu, maxMs: Single;
  fr, cp: array of Single;   // snapshot of the newest samples, taken under the engine lock

  function Min(a, b: Single): Single;
  begin
    if a < b then Result := a else Result := b;
  end;

  function YOf(ms: Single): Integer;
  begin
    Result := H - 4 - Round(ms / maxMs * (H - 22));
  end;

  procedure Series(useCpu: Boolean; col: TColor);
  var
    k: Integer;
  begin
    c.Pen.Color := col;
    c.Pen.Width := 1;
    for k := 0 to n - 1 do
    begin
      if useCpu then f := cp[k] else f := fr[k];
      x := W - n + k;
      y := YOf(Min(f, maxMs));
      if k = 0 then c.MoveTo(x, y) else c.LineTo(x, y);
    end;
  end;

begin
  c := pbGraph.Canvas;
  W := pbGraph.Width;
  H := pbGraph.Height;
  c.Brush.Color := RGBToColor(22, 26, 34);
  c.FillRect(0, 0, W, H);
  if FEngine = nil then Exit;

  FEngine.Lock;
  try
    n := FEngine.Stats.Count;
    if n > W then n := W;
    SetLength(fr, n);
    SetLength(cp, n);
    for i := 0 to n - 1 do
      FEngine.Stats.Get(FEngine.Stats.Count - n + i, fr[i], cp[i]);
  finally
    FEngine.Unlock;
  end;
  if n = 0 then Exit;

  maxMs := 40;
  for i := 0 to n - 1 do
    if fr[i] > maxMs then maxMs := fr[i];
  if maxMs > 100 then maxMs := 100;

  // reference lines: 60 FPS and 30 FPS budgets
  c.Font.Height := -11;
  c.Brush.Style := bsClear;
  c.Pen.Style := psDot;
  c.Pen.Color := RGBToColor(60, 140, 80);
  c.Line(0, YOf(16.7), W, YOf(16.7));
  c.Font.Color := RGBToColor(90, 170, 110);
  c.TextOut(4, YOf(16.7) - 13, '16.7 ms (60 FPS)');
  c.Pen.Color := RGBToColor(150, 70, 60);
  c.Line(0, YOf(33.3), W, YOf(33.3));
  c.Font.Color := RGBToColor(190, 100, 90);
  c.TextOut(4, YOf(33.3) - 13, '33.3 ms (30 FPS)');
  c.Pen.Style := psSolid;

  Series(False, RGBToColor(90, 200, 255));   // frame time
  Series(True, RGBToColor(255, 170, 60));    // cpu build time

  c.Font.Color := RGBToColor(200, 205, 215);
  c.TextOut(W - 250, 3, 'frame ms');
  c.Font.Color := RGBToColor(255, 170, 60);
  c.TextOut(W - 190, 3, 'cpu ms');
  c.Font.Color := RGBToColor(140, 145, 155);
  c.TextOut(W - 140, 3, Format('last %d frames', [n]));
  c.Brush.Style := bsSolid;
end;

{ ---- scene controls ---- }

procedure TDevForm.btnApplySeedClick(Sender: TObject);
begin
  FEngine.Post(ckSetSeed, seSeed.Value);
end;

procedure TDevForm.btnReseedClick(Sender: TObject);
begin
  FEngine.Post(ckReseed);
end;

procedure TDevForm.tbCellChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FEngine.Post(ckSetCell, 0, 0, tbCell.Position / 1000);
end;

procedure TDevForm.tbMotionChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FEngine.Post(ckSetMotion, 0, 0, tbMotion.Position / 100);
end;

procedure TDevForm.cbGlowChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FEngine.Post(ckSetGlow, cbGlow.ItemIndex);
end;

procedure TDevForm.cbAnimateChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FEngine.Post(ckSetPaused, 0, 0, 0, not cbAnimate.Checked);
end;

procedure TDevForm.cbScrollChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FEngine.Post(ckSetScroll, 0, 0, 0, cbScroll.Checked);
end;

procedure TDevForm.cbVignetteChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FEngine.Post(ckSetVignette, 0, 0, 0, cbVignette.Checked);
end;

procedure TDevForm.cbDimChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FEngine.Post(ckSetDim, 0, 0, 0, cbDim.Checked);
end;

procedure TDevForm.cbHudChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FEngine.Post(ckSetHud, 0, 0, 0, cbHud.Checked);
end;

procedure TDevForm.cbWinSizeChange(Sender: TObject);
var
  W, H: Integer;
begin
  if FUpdating then Exit;
  if ParseSize(cbWinSize.Text, W, H) then
    FEngine.Post(ckWindowSize, W, H);
end;

procedure TDevForm.btnFullscreenClick(Sender: TObject);
begin
  FEngine.Post(ckFullscreen);
end;

{ ---- export ---- }

// Report exports run here on the UI thread under the engine lock; image exports need the
// GL context, so they are posted to the render thread instead.

procedure TDevForm.btnExpJsonClick(Sender: TObject);
begin
  FEngine.Lock;
  try
    ExportStatusJson(FEngine, FEngine.NewExportName('status', 'json'));
  finally
    FEngine.Unlock;
  end;
end;

procedure TDevForm.btnExpTxtClick(Sender: TObject);
begin
  FEngine.Lock;
  try
    ExportStatusTxt(FEngine, FEngine.NewExportName('status', 'txt'));
  finally
    FEngine.Unlock;
  end;
end;

procedure TDevForm.ExportCsv;
var
  fn: string;
begin
  FEngine.Lock;
  try
    fn := FEngine.NewExportName('frames', 'csv');
    FEngine.Stats.SaveCsv(fn);
    FEngine.LastExport := fn;
    FEngine.Log('exported ' + ExtractFileName(fn));
  finally
    FEngine.Unlock;
  end;
end;

procedure TDevForm.btnExpCsvClick(Sender: TObject);
begin
  ExportCsv;
end;

procedure TDevForm.btnExpShotClick(Sender: TObject);
begin
  FEngine.Post(ckExportScreenshot);
end;

procedure TDevForm.btnExpRenderClick(Sender: TObject);
var
  W, H: Integer;
begin
  if ParseSize(cbRes.Text, W, H) then
    FEngine.Post(ckExportRender, W, H);
end;

procedure TDevForm.btnExpAllClick(Sender: TObject);
begin
  btnExpJsonClick(Sender);
  btnExpTxtClick(Sender);
  ExportCsv;
  btnExpShotClick(Sender);
  btnExpRenderClick(Sender);
end;

procedure TDevForm.btnOpenFolderClick(Sender: TObject);
begin
  ForceDirectories(FEngine.ExportDir);
  OpenDocument(FEngine.ExportDir);
end;

end.
