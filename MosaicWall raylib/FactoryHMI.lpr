program FactoryHMI;

{ Factory HMI (Assembly Line A) on the MosaicWall pattern — see SPEC_FactoryHMI.md.

  Keys: F1/F2/F3 (or 1/2/3) screens · B mosaic background on/off · F fullscreen · F12 screenshot
  Esc only closes the confirm dialog; the HMI itself closes with the window's X button,
  so a stray key press cannot shut down the operator station.

  Command line:
    --size WxH        window size (default 1600x900)
    --start           start the line at launch (default: stopped, the operator starts it)
    --nomosaic        plain background
    --shot FILE.png   headless: simulate, render one screen to FILE.png and exit
    --screen N        screen for --shot: 1 overview, 2 trends, 3 alarms (default 1)
    --sim S           seconds of simulation before --shot (default 180)
    --select N        station shown in the detail panel, 1..6
    --plc [HOST]      live data from a Siemens S7 PLC (S7 communication, TCP 102) instead of the
                      simulation; HOST default 127.0.0.1 (the Virtual PLC). See SPEC section 9.
    --plc-db N        number of the HMI data block (default 10)
    --plc-slot N      CPU slot (default: auto, tries 1, 2, 3, 0)
    With --plc, --shot waits --sim seconds of real time, and --start sends START LINE to the PLC. }

{$mode objfpc}{$H+}
{$APPTYPE GUI}

uses
  Windows, SysUtils, Math, raylib, uHmiTheme, uHmiWidgets, uFactoryHmi;

var
  Hmi: TFactoryHmi;
  WinW: Integer = 1600;
  WinH: Integer = 900;
  ShotFile: string = '';
  ShotScreen: Integer = 1;
  SimSeconds: Double = 180;
  StartLine: Boolean = False;
  NoMosaic: Boolean = False;
  SelectStation: Integer = 0;
  PlcHost: string = '';
  PlcDb: Integer = 10;
  PlcSlot: Integer = -1;

procedure Log(const s: string);
var
  h: THandle;
  line: string;
  written: DWORD;
begin
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  if (h = 0) or (h = INVALID_HANDLE_VALUE) then Exit;
  line := s + LineEnding;
  WriteFile(h, line[1], Length(line), written, nil);
end;

procedure ParseArgs;
var
  i, p: Integer;
  a, v: string;
begin
  i := 1;
  while i <= ParamCount do
  begin
    a := LowerCase(ParamStr(i));
    if i < ParamCount then v := ParamStr(i + 1) else v := '';
    if a = '--size' then
    begin
      p := Pos('x', LowerCase(v));
      if p > 0 then
      begin
        WinW := StrToIntDef(Copy(v, 1, p - 1), WinW);
        WinH := StrToIntDef(Copy(v, p + 1, MaxInt), WinH);
      end;
      Inc(i);
    end
    else if a = '--shot' then begin ShotFile := v; Inc(i); end
    else if a = '--screen' then begin ShotScreen := EnsureRange(StrToIntDef(v, 1), 1, 3); Inc(i); end
    else if a = '--sim' then begin SimSeconds := StrToFloatDef(v, 180); Inc(i); end
    else if a = '--select' then begin SelectStation := StrToIntDef(v, 0); Inc(i); end
    else if a = '--plc' then
    begin
      if (v <> '') and (Copy(v, 1, 2) <> '--') then begin PlcHost := v; Inc(i); end
      else PlcHost := '127.0.0.1';
    end
    else if a = '--plc-db' then begin PlcDb := StrToIntDef(v, PlcDb); Inc(i); end
    else if a = '--plc-slot' then begin PlcSlot := StrToIntDef(v, PlcSlot); Inc(i); end
    else if a = '--start' then StartLine := True
    else if a = '--nomosaic' then NoMosaic := True;
    Inc(i);
  end;
end;

procedure RunShot;
var
  t: Double;
  p: Integer;
  RT: TRenderTexture2D;
  img: TImage;
begin
  UiEnabled := False;
  t := 0;
  if PlcHost <> '' then
  begin
    // live: real time, so the driver reads the PLC; START LINE only when asked for (--start)
    while t < SimSeconds do
    begin
      if StartLine and (t >= 1) then
      begin
        Hmi.Plant.StartLine;
        StartLine := False;
      end;
      Sleep(50);
      Hmi.Update(0.05);
      t := t + 0.05;
    end;
    for p := 0 to Hmi.Plant.Events.Count - 1 do Log(Hmi.Plant.Events[p]);
  end
  else
  begin
    Hmi.Plant.StartLine;
    while t < SimSeconds do
    begin
      Hmi.Update(0.05);
      t := t + 0.05;
    end;
  end;
  Hmi.Screen := THmiScreen(ShotScreen - 1);
  RT := LoadRenderTexture(WinW, WinH);
  BeginDrawing;
    BeginTextureMode(RT);
      Hmi.Draw(WinW, WinH);
    EndTextureMode;
  EndDrawing;
  img := LoadImageFromTexture(RT.texture);
  ImageFlipVertical(@img);
  ImageFormat(@img, PIXELFORMAT_UNCOMPRESSED_R8G8B8);
  if ExportImage(img, PChar(ShotFile)) then
    Log(Format('saved %s (%dx%d, screen %d, %.0f s simulated, %d alarms open)',
      [ShotFile, WinW, WinH, ShotScreen, SimSeconds, Hmi.Plant.Alarms.OpenCount]))
  else
    Log('failed to save ' + ShotFile);
  UnloadImage(img);
  UnloadRenderTexture(RT);
end;

procedure RunInteractive;
begin
  if StartLine then Hmi.Plant.StartLine;
  while not WindowShouldClose do
  begin
    Hmi.HandleKeys;
    if IsKeyPressed(KEY_F) then ToggleFullscreen;
    Hmi.Update(GetFrameTime);
    BeginDrawing;
      Hmi.Draw(GetScreenWidth, GetScreenHeight);
    EndDrawing;
  end;
end;

begin
  ParseArgs;
  SetTraceLogLevel(LOG_WARNING);
  if ShotFile <> '' then
  begin
    SetConfigFlags(FLAG_WINDOW_HIDDEN);
    InitWindow(64, 64, 'Factory HMI');
  end
  else
  begin
    SetConfigFlags(FLAG_VSYNC_HINT or FLAG_WINDOW_RESIZABLE or FLAG_MSAA_4X_HINT);
    InitWindow(WinW, WinH, 'Factory HMI - Assembly Line A');
    SetWindowMinSize(1024, 576);
    SetExitKey(KEY_NULL);
    SetTargetFPS(60);
  end;
  LoadHmiFonts;
  Hmi := TFactoryHmi.Create;
  try
    Hmi.ShowMosaic := not NoMosaic;
    if (SelectStation >= 1) and (SelectStation <= 6) then Hmi.Selected := SelectStation - 1;
    if PlcHost <> '' then Hmi.ConnectPlc(PlcHost, PlcDb, PlcSlot);
    if ShotFile <> '' then RunShot else RunInteractive;
  finally
    Hmi.Free;
    UnloadHmiFonts;
    CloseWindow;
  end;
end.
