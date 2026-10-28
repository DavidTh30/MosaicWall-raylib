unit uMosaicEngine;

{ The MosaicWall runtime: raylib window, per-frame loop, keyboard controls, HUD, static bake,
  re-seed cross-fade, statistics and image export. Used by both MosaicWall.exe (plain loop)
  and MosaicWallDev.exe (on its own render thread next to the developer status window).

  Other code changes the engine through Post(): commands run at the start of the next Frame,
  so a button click never lands in the middle of raylib's drawing.

  Threading: everything raylib (Open, Frame, Close, exports) runs on one thread — the main
  thread in MosaicWall.exe, a dedicated render thread in MosaicWallDev.exe. Other threads may
  only call Post/Log, or read the public fields between Lock and Unlock. Frame holds the lock
  while it updates and draws, and releases it before EndDrawing (swap + vsync wait). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, raylib, uMosaicTypes, uMosaicGen, uMosaicRender, uMosaicStats;

type
  TEngineCmdKind = (ckReseed, ckSetSeed, ckSetCell, ckSetGlow, ckSetPaused, ckSetScroll,
    ckSetVignette, ckSetDim, ckSetHud, ckSetMotion, ckFullscreen, ckWindowSize,
    ckExportScreenshot, ckExportRender);

  TEngineCmd = record
    Kind: TEngineCmdKind;
    I1, I2: Integer;
    F: Single;
    B: Boolean;
    S: string;
  end;

  TMosaicEngine = class
  private
    FRenderer: TMosaicRenderer;
    FBakeRT, FSnapRT: TRenderTexture2D;
    FBakeW, FBakeH, FSnapW, FSnapH: Integer;
    FBakeDirty: Boolean;
    FOpened: Boolean;
    FQueue: array of TEngineCmd;
    FLastFrameStart: Double;
    FLastCpuMs: Single;
    FLastSwapMs: Single;       // time inside EndDrawing (swap + vsync wait + event polling)
    FLastFrameEnd: Double;     // to measure time spent outside Frame (host UI work)
    FLock: TRTLCriticalSection;   // recursive on Windows
    function FrameBody: Boolean;
    procedure EnsureRT(var RT: TRenderTexture2D; var W, H: Integer; NW, NH: Integer);
    procedure RenderInto(var RT: TRenderTexture2D; const M: TMosaic; t: Single);
    procedure Regenerate;
    procedure Analyze;
    procedure HandleKeys;
    procedure RunCommand(const C: TEngineCmd);
    procedure DrawHud;
    function RenderToFile(const M: TMosaic; const FileName: string; t: Single): Boolean;
  public
    Cfg: TMosaicConfig;
    Mosaic: TMosaic;
    Stats: TMosaicStats;
    Paused, ShowHud: Boolean;
    AnimTime: Double;
    FadeLeft: Single;
    Width, Height: Integer;
    GLVendor, GLRenderer, GLVersion: string;
    ExportDir, LastExport: string;
    // scene analysis, refreshed on every regenerate
    GridCols, GridRows: Integer;
    VividCount, BridgeCount, GlowCount, GlintCount: Integer;
    ZoneCounts: array[0..3] of Integer;
    GenMs: Single;
    UiRefreshMs: Double;      // set by the status window: time its last refresh took

    constructor Create;
    destructor Destroy; override;
    procedure Open(W, H: Integer; Hidden: Boolean; const Title: string);
    procedure Close;
    // one frame; False once the window wants to close
    function Frame: Boolean;
    procedure Post(Kind: TEngineCmdKind; I1: Integer = 0; I2: Integer = 0; F: Single = 0;
      B: Boolean = False; const S: string = '');
    procedure Log(const Msg: string);
    function NewExportName(const Suffix, Ext: string): string;
    // immediate exports (call between frames, never inside BeginDrawing)
    function ExportScreenshot(const FileName: string): Boolean;
    function ExportRender(const FileName: string; W, H: Integer; t: Single): Boolean;
    function Bench(W, H, Frames: Integer): string;
    function GpuBytes: Int64;
    function DrawCalls: Integer;
    function StateText: string;
    procedure MoveWindow(X, Y: Integer);
    procedure Lock;
    procedure Unlock;
    property Opened: Boolean read FOpened;
  end;

function NextSeed(s: LongWord): LongWord;

implementation

uses
  Math, uSysInfo;

const
  FADE_TIME = 0.6;

function NextSeed(s: LongWord): LongWord;
begin
  {$push}{$Q-}{$R-}
  Result := s * 1103515245 + 12345;
  {$pop}
  Result := (Result shr 8) mod 1000000;
end;

constructor TMosaicEngine.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  Cfg := DefaultMosaicConfig;
  Stats := TMosaicStats.Create;
  ExportDir := ExtractFilePath(ParamStr(0)) + 'export';
  FBakeDirty := True;
end;

destructor TMosaicEngine.Destroy;
begin
  Close;
  Stats.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TMosaicEngine.Lock;
begin
  EnterCriticalSection(FLock);
end;

procedure TMosaicEngine.Unlock;
begin
  LeaveCriticalSection(FLock);
end;

procedure TMosaicEngine.Open(W, H: Integer; Hidden: Boolean; const Title: string);
begin
  Lock;
  try
  SetTraceLogLevel(LOG_WARNING);
  if Hidden then
    SetConfigFlags(FLAG_WINDOW_HIDDEN)
  else
    SetConfigFlags(FLAG_VSYNC_HINT or FLAG_WINDOW_RESIZABLE or FLAG_MSAA_4X_HINT);
  InitWindow(W, H, PChar(Title));
  if not Hidden then SetTargetFPS(60);
  ReadGLStrings(GLVendor, GLRenderer, GLVersion);
  FRenderer := TMosaicRenderer.Create;
  FOpened := True;
  Width := GetScreenWidth;
  Height := GetScreenHeight;
  Regenerate;
  Log(Format('window opened %dx%d, OpenGL %s', [Width, Height, GLVersion]));
  finally
    Unlock;
  end;
end;

procedure TMosaicEngine.Close;
begin
  Lock;
  try
    if not FOpened then Exit;
    FreeAndNil(FRenderer);
    if FBakeW > 0 then UnloadRenderTexture(FBakeRT);
    if FSnapW > 0 then UnloadRenderTexture(FSnapRT);
    FBakeW := 0; FSnapW := 0;
    CloseWindow;
    FOpened := False;
  finally
    Unlock;
  end;
end;

procedure TMosaicEngine.Log(const Msg: string);
begin
  Lock;
  try
    Stats.AddEvent(Msg);
  finally
    Unlock;
  end;
end;

procedure TMosaicEngine.EnsureRT(var RT: TRenderTexture2D; var W, H: Integer; NW, NH: Integer);
begin
  if (W = NW) and (H = NH) then Exit;
  if W > 0 then UnloadRenderTexture(RT);
  RT := LoadRenderTexture(NW, NH);
  W := NW; H := NH;
end;

procedure TMosaicEngine.RenderInto(var RT: TRenderTexture2D; const M: TMosaic; t: Single);
begin
  FRenderer.PrepareGlow(M, Cfg, t);
  BeginTextureMode(RT);
  FRenderer.DrawScene(M, Cfg, t);
  EndTextureMode;
end;

procedure TMosaicEngine.Regenerate;
var
  t0: Double;
begin
  t0 := GetTime;
  GenerateMosaic(Cfg, Width, Height, Mosaic);
  GenMs := (GetTime - t0) * 1000;
  FBakeDirty := True;
  Analyze;
end;

procedure TMosaicEngine.Analyze;
var
  i, z: Integer;
  yN: Single;
begin
  GridCols := Ceil(Width / Mosaic.Cell) + 2;
  GridRows := Ceil(Height / Mosaic.Cell) + 2;
  VividCount := 0; BridgeCount := 0; GlowCount := 0; GlintCount := 0;
  FillChar(ZoneCounts, SizeOf(ZoneCounts), 0);
  for i := 0 to High(Mosaic.Accent) do
    with Mosaic.Accent[i] do
    begin
      if kind = tkAccent then Inc(VividCount);
      if bridgeTo >= 0 then Inc(BridgeCount);
      if hasGlow then Inc(GlowCount);
      if hasGlint then Inc(GlintCount);
      yN := cy / Height;
      if yN < 0.45 then z := 0
      else if yN < 0.62 then z := 1
      else if yN < 0.80 then z := 2
      else z := 3;
      Inc(ZoneCounts[z]);
    end;
end;

procedure TMosaicEngine.Post(Kind: TEngineCmdKind; I1: Integer; I2: Integer; F: Single;
  B: Boolean; const S: string);
var
  n: Integer;
begin
  Lock;
  try
    n := Length(FQueue);
    SetLength(FQueue, n + 1);
    FQueue[n].Kind := Kind;
    FQueue[n].I1 := I1;
    FQueue[n].I2 := I2;
    FQueue[n].F := F;
    FQueue[n].B := B;
    FQueue[n].S := S;
  finally
    Unlock;
  end;
end;

function TMosaicEngine.NewExportName(const Suffix, Ext: string): string;
begin
  ForceDirectories(ExportDir);
  Result := IncludeTrailingPathDelimiter(ExportDir) +
    Format('mosaic_%d_%s_%s.%s', [Cfg.Seed, FormatDateTime('yyyymmdd_hhnnss', Now), Suffix, Ext]);
end;

procedure TMosaicEngine.RunCommand(const C: TEngineCmd);
var
  fn: string;
begin
  case C.Kind of
    ckReseed, ckSetSeed:
      begin
        // snapshot the current picture, then cross-fade from it into the new seed
        EnsureRT(FSnapRT, FSnapW, FSnapH, Width, Height);
        RenderInto(FSnapRT, Mosaic, AnimTime);
        if C.Kind = ckReseed then Cfg.Seed := NextSeed(Cfg.Seed)
        else Cfg.Seed := LongWord(C.I1);
        Regenerate;
        FadeLeft := FADE_TIME;
        Log(Format('seed -> %d (%d base, %d accent, generated in %.2f ms)',
          [Cfg.Seed, Length(Mosaic.Base), Length(Mosaic.Accent), GenMs]));
      end;
    ckSetCell:
      begin
        Cfg.CellRatio := EnsureRange(C.F, CELL_RATIO_MIN, CELL_RATIO_MAX);
        Regenerate;
        Log(Format('cell ratio -> %.3f (%.0f px)', [Cfg.CellRatio, Mosaic.Cell]));
      end;
    ckSetGlow:
      begin
        Cfg.GlowMode := EnsureRange(C.I1, 0, 2);
        Log(Format('glow mode -> %d', [Cfg.GlowMode]));
      end;
    ckSetPaused:
      begin
        Paused := C.B;
        Log(BoolToStr(Paused, 'animation paused (static bake)', 'animation resumed'));
      end;
    ckSetScroll:
      begin
        Cfg.GradientScroll := C.B;
        Log('gradient scroll ' + BoolToStr(C.B, 'on', 'off'));
      end;
    ckSetVignette:
      begin
        if C.B then Cfg.Vignette := 0.12 else Cfg.Vignette := 0;
        Log('vignette ' + BoolToStr(C.B, 'on', 'off'));
      end;
    ckSetDim:
      begin
        Cfg.Dim := C.B;
        Log('dim ' + BoolToStr(C.B, 'on', 'off'));
      end;
    ckSetHud:
      ShowHud := C.B;
    ckSetMotion:
      begin
        Cfg.Motion := EnsureRange(C.F, 0, MOTION_MAX);
        Log(Format('motion -> %.0f%%', [Cfg.Motion * 100]));
      end;
    ckFullscreen:
      begin
        ToggleFullscreen;
        Log('toggle fullscreen');
      end;
    ckWindowSize:
      begin
        SetWindowSize(C.I1, C.I2);
        Log(Format('window size -> %dx%d', [C.I1, C.I2]));
      end;
    ckExportScreenshot:
      begin
        fn := C.S;
        if fn = '' then fn := NewExportName('screen', 'png');
        ExportScreenshot(fn);
      end;
    ckExportRender:
      begin
        fn := C.S;
        if fn = '' then fn := NewExportName(Format('%dx%d', [C.I1, C.I2]), 'png');
        ExportRender(fn, C.I1, C.I2, AnimTime);
      end;
  end;
  FBakeDirty := True;
end;

procedure TMosaicEngine.HandleKeys;
begin
  if IsKeyPressed(KEY_R) then Post(ckReseed);
  if IsKeyPressed(KEY_SPACE) or IsKeyPressed(KEY_P) then Post(ckSetPaused, 0, 0, 0, not Paused);
  if IsKeyPressed(KEY_G) then Post(ckSetGlow, (Cfg.GlowMode + 1) mod 3);
  if IsKeyPressed(KEY_EQUAL) or IsKeyPressed(KEY_KP_ADD) then Post(ckSetCell, 0, 0, Cfg.CellRatio + 0.005);
  if IsKeyPressed(KEY_MINUS) or IsKeyPressed(KEY_KP_SUBTRACT) then Post(ckSetCell, 0, 0, Cfg.CellRatio - 0.005);
  if IsKeyPressed(KEY_S) then Post(ckSetScroll, 0, 0, 0, not Cfg.GradientScroll);
  if IsKeyPressed(KEY_V) then Post(ckSetVignette, 0, 0, 0, Cfg.Vignette <= 0);
  if IsKeyPressed(KEY_D) then Post(ckSetDim, 0, 0, 0, not Cfg.Dim);
  if IsKeyPressed(KEY_F) then Post(ckFullscreen);
  if IsKeyPressed(KEY_H) then Post(ckSetHud, 0, 0, 0, not ShowHud);
  if IsKeyPressed(KEY_RIGHT_BRACKET) then Post(ckSetMotion, 0, 0, Cfg.Motion + 0.25);
  if IsKeyPressed(KEY_LEFT_BRACKET) then Post(ckSetMotion, 0, 0, Cfg.Motion - 0.25);
  if IsKeyPressed(KEY_F12) then Post(ckExportScreenshot);
end;

procedure TMosaicEngine.DrawHud;
var
  lines: array[0..3] of string;
  i, w, maxW: Integer;
const
  FS = 16;
begin
  lines[0] := Format('FPS %d   seed %d   tiles %d/%d   cell %.3f',
    [GetFPS, Cfg.Seed, Length(Mosaic.Base), Length(Mosaic.Accent), Cfg.CellRatio]);
  lines[1] := Format('glow %d   motion %.0f%%   vignette %s   anim %s   scroll %s   dim %s',
    [Cfg.GlowMode, Cfg.Motion * 100, BoolToStr(Cfg.Vignette > 0, 'on', 'off'),
     BoolToStr(Paused, 'paused', 'on'), BoolToStr(Cfg.GradientScroll, 'on', 'off'),
     BoolToStr(Cfg.Dim, 'on', 'off')]);
  lines[2] := 'R reseed  Space/P pause  G glow  +/- cell  [ ] motion  S scroll  V vignette';
  lines[3] := 'D dim  F fullscreen  H hud  F12 export png  Esc quit';
  maxW := 0;
  for i := 0 to High(lines) do
  begin
    w := MeasureText(PChar(lines[i]), FS);
    if w > maxW then maxW := w;
  end;
  DrawRectangle(8, 8, maxW + 16, Length(lines) * (FS + 4) + 12, ColorRGBA(0, 0, 0, 160));
  for i := 0 to High(lines) do
    DrawText(PChar(lines[i]), 16, 14 + i * (FS + 4), FS, WHITE);
end;

function TMosaicEngine.Frame: Boolean;
var
  t1: Double;
begin
  Lock;
  try
    Result := FrameBody;
  finally
    Unlock;
  end;
  if not Result then Exit;
  // outside the lock: the swap can wait for vsync, other threads should not wait with it
  t1 := GetTime;
  EndDrawing;
  FLastFrameEnd := GetTime;
  FLastSwapMs := (FLastFrameEnd - t1) * 1000;
end;

// update + draw up to (not including) EndDrawing; False when the window should close
function TMosaicEngine.FrameBody: Boolean;
var
  t0, dt: Double;
  i: Integer;
  q: array of TEngineCmd;
begin
  t0 := GetTime;
  if FLastFrameStart > 0 then
    Stats.Push((t0 - FLastFrameStart) * 1000, FLastCpuMs, FLastSwapMs, (t0 - FLastFrameEnd) * 1000);
  FLastFrameStart := t0;

  if WindowShouldClose then Exit(False);
  Result := True;

  if (GetScreenWidth <> Width) or (GetScreenHeight <> Height) or IsWindowResized then
  begin
    Width := Max(1, GetScreenWidth);
    Height := Max(1, GetScreenHeight);
    Regenerate;
    Log(Format('resized -> %dx%d, regenerated in %.2f ms', [Width, Height, GenMs]));
  end;

  HandleKeys;
  q := FQueue;
  FQueue := nil;
  for i := 0 to High(q) do RunCommand(q[i]);

  dt := GetFrameTime;
  if not Paused then AnimTime := AnimTime + dt;
  if FadeLeft > 0 then FadeLeft := Max(0, FadeLeft - dt);

  // static mode: bake once into a render texture and blit it every frame
  if Paused and (FadeLeft <= 0) and FBakeDirty then
  begin
    EnsureRT(FBakeRT, FBakeW, FBakeH, Width, Height);
    RenderInto(FBakeRT, Mosaic, AnimTime);
    FBakeDirty := False;
  end;
  if (not Paused) or (FadeLeft > 0) then
    FRenderer.PrepareGlow(Mosaic, Cfg, AnimTime);

  BeginDrawing;
  if Paused and (FadeLeft <= 0) then
  begin
    ClearBackground(BLACK);
    DrawSceneTexture(FBakeRT, Width, Height, 1);
  end
  else
  begin
    FRenderer.DrawScene(Mosaic, Cfg, AnimTime);
    if FadeLeft > 0 then
      DrawSceneTexture(FSnapRT, Width, Height, FadeLeft / FADE_TIME);
    FBakeDirty := True;
  end;
  if ShowHud then DrawHud;
  FLastCpuMs := (GetTime - t0) * 1000;
end;

function TMosaicEngine.RenderToFile(const M: TMosaic; const FileName: string; t: Single): Boolean;
var
  RT: TRenderTexture2D;
  img: TImage;
begin
  ForceDirectories(ExtractFileDir(ExpandFileName(FileName)));
  RT := LoadRenderTexture(M.Width, M.Height);
  RenderInto(RT, M, t);
  img := LoadImageFromTexture(RT.texture);
  ImageFlipVertical(@img);
  ImageFormat(@img, PIXELFORMAT_UNCOMPRESSED_R8G8B8);   // drop the RT alpha channel
  Result := ExportImage(img, PChar(FileName));
  UnloadImage(img);
  UnloadRenderTexture(RT);
  if Result then
  begin
    LastExport := FileName;
    Log(Format('exported %s (%dx%d)', [ExtractFileName(FileName), M.Width, M.Height]));
  end
  else
    Log('EXPORT FAILED: ' + FileName);
end;

function TMosaicEngine.ExportScreenshot(const FileName: string): Boolean;
begin
  // re-render the current scene (without HUD) instead of reading the back buffer
  Result := RenderToFile(Mosaic, FileName, AnimTime);
end;

function TMosaicEngine.ExportRender(const FileName: string; W, H: Integer; t: Single): Boolean;
var
  M: TMosaic;
begin
  GenerateMosaic(Cfg, W, H, M);
  Result := RenderToFile(M, FileName, t);
end;

function TMosaicEngine.Bench(W, H, Frames: Integer): string;
var
  RT: TRenderTexture2D;
  M: TMosaic;
  i: Integer;
  t0, t1: Double;
begin
  GenerateMosaic(Cfg, W, H, M);
  RT := LoadRenderTexture(W, H);
  t0 := GetTime;
  for i := 1 to Frames do
  begin
    BeginDrawing;
    RenderInto(RT, M, i / 60);
    DrawSceneTexture(RT, GetScreenWidth, GetScreenHeight, 1);
    EndDrawing;
  end;
  t1 := GetTime;
  UnloadRenderTexture(RT);
  Result := Format('bench %dx%d glow %d: %d frames, %.2f ms/frame (%.0f FPS), %d base + %d accent tiles',
    [W, H, Cfg.GlowMode, Frames, (t1 - t0) * 1000 / Frames,
     Frames / Max(1e-6, t1 - t0), Length(M.Base), Length(M.Accent)]);
end;

function TMosaicEngine.GpuBytes: Int64;
begin
  Result := 0;
  if FRenderer <> nil then Result := FRenderer.GpuBytes;
  if FBakeW > 0 then Result := Result + Int64(FBakeW) * FBakeH * 8;
  if FSnapW > 0 then Result := Result + Int64(FSnapW) * FSnapH * 8;
end;

function TMosaicEngine.DrawCalls: Integer;
begin
  Result := 0;
  if Paused and (FadeLeft <= 0) then Exit(1);   // only the baked texture is drawn
  if FRenderer <> nil then Result := FRenderer.Prims + FRenderer.GlowPrims;
end;

procedure TMosaicEngine.MoveWindow(X, Y: Integer);
begin
  if FOpened then SetWindowPosition(X, Y);
end;

function TMosaicEngine.StateText: string;
begin
  if FadeLeft > 0 then Result := 'cross-fading'
  else if Paused then Result := 'paused (baked)'
  else Result := 'running';
end;

end.
