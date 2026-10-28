program MosaicWall;

{ Procedural mosaic wallpaper — see SPEC_MosaicWallpaper.md.
  For the version with the developer status window, open MosaicWallDev.lpi.

  Command line:
    --seed N          start seed (default 653)
    --size WxH        window size (default 540x960)
    --glow N          glow mode 0/1/2
    --motion P        animation strength in percent, 0..300 (default 100)
    --cell R          cell size as a fraction of the width, 0.04..0.12 (default 0.076)
    --static          start paused
    --shot FILE.png   render one frame off-screen and exit (uses --render size)
    --render WxH      off-screen size for --shot (default 1080x1920)
    --time T          animation time used for --shot (default 0)
    --bench N         render N animated frames off-screen at --render size, print ms/frame and exit }

{$mode objfpc}{$H+}
{$APPTYPE GUI}   // no extra black console window; --shot/--bench output still reaches a redirected stdout

uses
  Windows, SysUtils, Math, uMosaicTypes, uMosaicEngine;

var
  Engine: TMosaicEngine;
  WinW: Integer = 540;  WinH: Integer = 960;
  StartPaused: Boolean = False;
  ShotFile: string = '';
  ShotW: Integer = 1080; ShotH: Integer = 1920;
  ShotTime: Single = 0;
  BenchFrames: Integer = 0;

procedure Log(const s: string);
var
  h: THandle;
  line: string;
  written: DWORD;
begin
  // GUI app: FPC does not open Output, so write straight to the inherited stdout handle
  // (a pipe/redirect from the shell); with no handle (started from Explorer) nothing happens
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  if (h = 0) or (h = INVALID_HANDLE_VALUE) then Exit;
  line := s + LineEnding;
  WriteFile(h, line[1], Length(line), written, nil);
end;

procedure ParseSize(const s: string; var W, H: Integer);
var
  p: Integer;
begin
  p := Pos('x', LowerCase(s));
  if p > 0 then
  begin
    W := StrToIntDef(Copy(s, 1, p - 1), W);
    H := StrToIntDef(Copy(s, p + 1, MaxInt), H);
  end;
end;

procedure ParseArgs;
var
  i: Integer;
  a: string;
begin
  i := 1;
  while i <= ParamCount do
  begin
    a := LowerCase(ParamStr(i));
    if (a = '--seed') and (i < ParamCount) then
    begin Inc(i); Engine.Cfg.Seed := StrToIntDef(ParamStr(i), Engine.Cfg.Seed); end
    else if (a = '--size') and (i < ParamCount) then
    begin Inc(i); ParseSize(ParamStr(i), WinW, WinH); end
    else if (a = '--render') and (i < ParamCount) then
    begin Inc(i); ParseSize(ParamStr(i), ShotW, ShotH); end
    else if (a = '--glow') and (i < ParamCount) then
    begin Inc(i); Engine.Cfg.GlowMode := EnsureRange(StrToIntDef(ParamStr(i), 1), 0, 2); end
    else if (a = '--cell') and (i < ParamCount) then
    begin
      Inc(i);
      Engine.Cfg.CellRatio := EnsureRange(StrToFloatDef(ParamStr(i), 0.076), CELL_RATIO_MIN, CELL_RATIO_MAX);
    end
    else if (a = '--motion') and (i < ParamCount) then
    begin Inc(i); Engine.Cfg.Motion := EnsureRange(StrToIntDef(ParamStr(i), 100), 0, 300) / 100; end
    else if (a = '--time') and (i < ParamCount) then
    begin Inc(i); ShotTime := StrToFloatDef(ParamStr(i), 0); end
    else if (a = '--shot') and (i < ParamCount) then
    begin Inc(i); ShotFile := ParamStr(i); end
    else if (a = '--bench') and (i < ParamCount) then
    begin Inc(i); BenchFrames := Max(1, StrToIntDef(ParamStr(i), 300)); end
    else if a = '--static' then
      StartPaused := True;
    Inc(i);
  end;
end;

begin
  Engine := TMosaicEngine.Create;
  try
    ParseArgs;
    if (ShotFile <> '') or (BenchFrames > 0) then
    begin
      Engine.Open(64, 64, True, 'Mosaic Wallpaper');
      if BenchFrames > 0 then
        Log(Engine.Bench(ShotW, ShotH, BenchFrames))
      else if Engine.ExportRender(ShotFile, ShotW, ShotH, ShotTime) then
        Log(Format('saved %s (%dx%d, seed %d)', [ShotFile, ShotW, ShotH, Engine.Cfg.Seed]))
      else
        Log('failed to save ' + ShotFile);
    end
    else
    begin
      Engine.Open(WinW, WinH, False, 'Mosaic Wallpaper');
      Engine.Paused := StartPaused;
      while Engine.Frame do ;
    end;
  finally
    Engine.Free;
  end;
end.
