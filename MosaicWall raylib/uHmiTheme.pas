unit uHmiTheme;

{ Look of the factory HMI: colours from the mosaic palette, fonts, text helpers, mosaic-style
  panels and the status / alarm icons.

  Colour rules (ISA-101 "high performance HMI"):
  - normal operation is drawn in neutral blue-grey; colour is reserved for abnormal states,
  - alarm colours (red / amber / yellow) are never used for anything else,
  - every state is shown with a shape and a text label too, never by colour alone. }

{$mode objfpc}{$H+}

interface

uses
  raylib, uAlarms, uPlantSim;

type
  THAlign = (haLeft, haCenter, haRight);

var
  FontUI, FontBold, FontNum: TFont;

const
  // surfaces (mosaic BASE family)
  C_BG: TColor        = (r: 6;   g: 16;  b: 27;  a: 255);
  C_VEIL: TColor      = (r: 6;   g: 16;  b: 27;  a: 165);   // calms the mosaic behind the UI
  C_PANEL: TColor     = (r: 10;  g: 31;  b: 50;  a: 228);
  C_PANEL_HI: TColor  = (r: 16;  g: 46;  b: 72;  a: 240);
  C_RIM: TColor       = (r: 34;  g: 76;  b: 108; a: 255);
  C_TOPBAR: TColor    = (r: 4;   g: 12;  b: 21;  a: 238);
  C_GRID: TColor      = (r: 40;  g: 70;  b: 96;  a: 255);
  // text
  C_TEXT: TColor      = (r: 230; g: 238; b: 245; a: 255);
  C_TEXT2: TColor     = (r: 160; g: 180; b: 200; a: 255);
  C_MUTED: TColor     = (r: 104; g: 128; b: 152; a: 255);
  // interaction / normal accent (mosaic SKY)
  C_ACCENT: TColor    = (r: 48;  g: 148; b: 200; a: 255);
  C_ACCENT_DIM: TColor= (r: 24;  g: 74;  b: 104; a: 255);
  // process states
  C_RUN: TColor       = (r: 76;  g: 175; b: 110; a: 255);
  C_STOP: TColor      = (r: 120; g: 136; b: 152; a: 255);
  C_WAIT: TColor      = (r: 150; g: 170; b: 190; a: 255);
  C_MAINT: TColor     = (r: 66;  g: 140; b: 230; a: 255);
  // alarm priorities (reserved)
  C_CRIT: TColor      = (r: 229; g: 57;  b: 53;  a: 255);
  C_HIGH: TColor      = (r: 255; g: 160; b: 0;   a: 255);
  C_MED: TColor       = (r: 240; g: 214; b: 60;  a: 255);

procedure LoadHmiFonts;
procedure UnloadHmiFonts;

function TextWidth(const F: TFont; const S: string; Size: Single): Single;
procedure Txt(const F: TFont; const S: string; X, Y, Size: Single; C: TColor; Align: THAlign = haLeft);
// text vertically centred in a rect
procedure TxtIn(const F: TFont; const S: string; const R: TRectangle; Size: Single; C: TColor;
  Align: THAlign = haLeft; Pad: Single = 0);

function Fade(C: TColor; A: Byte): TColor;
function Mix(A, B: TColor; T: Single): TColor;
function RectI(X, Y, W, H: Single): TRectangle;
function Inset(const R: TRectangle; D: Single): TRectangle;

// mosaic-tile panel: shadow, rim, fill, light top edge
procedure Panel(const R: TRectangle; Fill: TColor; Rim: TColor; Roundness: Single = 0.08);
procedure PanelTitle(const R: TRectangle; const Title: string);

function StateColor(S: TStationState): TColor;
procedure StateIcon(S: TStationState; CX, CY, Size: Single; Blink: Boolean);
function PriorityColor(P: TAlarmPriority): TColor;
// distinct shape per priority: critical = diamond, high = triangle, medium = square
procedure AlarmIcon(P: TAlarmPriority; CX, CY, Size: Single);
procedure MosaicLogo(X, Y, Size: Single);

implementation

uses
  SysUtils, Math;

const
  FONT_ATLAS = 64;

function LoadOne(const Files: array of string): TFont;
var
  cps: array of Integer;
  i, n: Integer;
  f: string;
begin
  // ASCII + the few symbols the HMI uses: ° · × – →
  SetLength(cps, 95 + 5);
  n := 0;
  for i := 32 to 126 do begin cps[n] := i; Inc(n); end;
  cps[n] := 176; Inc(n);
  cps[n] := 183; Inc(n);
  cps[n] := 215; Inc(n);
  cps[n] := 8211; Inc(n);
  cps[n] := 8594; Inc(n);
  for f in Files do
    if FileExists(f) then
    begin
      Result := LoadFontEx(PChar(f), FONT_ATLAS, @cps[0], n);
      if Result.glyphCount > 0 then
      begin
        // mipmaps + trilinear: the UI is scaled to the window, text must stay sharp when shrunk
        GenTextureMipmaps(@Result.texture);
        SetTextureFilter(Result.texture, TEXTURE_FILTER_TRILINEAR);
        Exit;
      end;
    end;
  Result := GetFontDefault;
end;

procedure LoadHmiFonts;
const
  FD = 'C:\Windows\Fonts\';
begin
  FontUI := LoadOne([FD + 'segoeui.ttf', FD + 'arial.ttf']);
  FontBold := LoadOne([FD + 'segoeuib.ttf', FD + 'arialbd.ttf']);
  // DIN-like face for numbers; falls back to Segoe UI
  FontNum := LoadOne([FD + 'bahnschrift.ttf', FD + 'segoeuisl.ttf', FD + 'segoeui.ttf']);
end;

procedure UnloadHmiFonts;
var
  d: TFont;
begin
  d := GetFontDefault;
  if FontUI.texture.id <> d.texture.id then UnloadFont(FontUI);
  if FontBold.texture.id <> d.texture.id then UnloadFont(FontBold);
  if FontNum.texture.id <> d.texture.id then UnloadFont(FontNum);
end;

function TextWidth(const F: TFont; const S: string; Size: Single): Single;
begin
  Result := MeasureTextEx(F, PChar(S), Size, 0).x;
end;

procedure Txt(const F: TFont; const S: string; X, Y, Size: Single; C: TColor; Align: THAlign);
begin
  case Align of
    haCenter: X := X - TextWidth(F, S, Size) / 2;
    haRight: X := X - TextWidth(F, S, Size);
  end;
  DrawTextEx(F, PChar(S), Vec2(Round(X), Round(Y)), Size, 0, C);
end;

procedure TxtIn(const F: TFont; const S: string; const R: TRectangle; Size: Single; C: TColor;
  Align: THAlign; Pad: Single);
var
  x: Single;
begin
  case Align of
    haLeft: x := R.x + Pad;
    haCenter: x := R.x + R.width / 2;
  else
    x := R.x + R.width - Pad;
  end;
  // fonts sit a little high in their line box; 0.55 centres cap height visually
  Txt(F, S, x, R.y + R.height / 2 - Size * 0.55, Size, C, Align);
end;

function Fade(C: TColor; A: Byte): TColor;
begin
  Result := C;
  Result.a := A;
end;

function Mix(A, B: TColor; T: Single): TColor;
begin
  Result.r := Round(A.r + (B.r - A.r) * T);
  Result.g := Round(A.g + (B.g - A.g) * T);
  Result.b := Round(A.b + (B.b - A.b) * T);
  Result.a := Round(A.a + (B.a - A.a) * T);
end;

function RectI(X, Y, W, H: Single): TRectangle;
begin
  Result := Rect(X, Y, W, H);
end;

function Inset(const R: TRectangle; D: Single): TRectangle;
begin
  Result := Rect(R.x + D, R.y + D, R.width - 2 * D, R.height - 2 * D);
end;

procedure Panel(const R: TRectangle; Fill: TColor; Rim: TColor; Roundness: Single);
var
  sh: TRectangle;
begin
  sh := Rect(R.x + 3, R.y + 4, R.width, R.height);
  DrawRectangleRounded(sh, Roundness, 6, ColorRGBA(0, 0, 0, 70));
  DrawRectangleRounded(Rect(R.x - 1, R.y - 1, R.width + 2, R.height + 2), Roundness, 6, Rim);
  DrawRectangleRounded(R, Roundness, 6, Fill);
  // light top edge, like the inner shade of a mosaic tile
  DrawRectangleRounded(Rect(R.x + 6, R.y + 2, R.width - 12, Min(18, R.height * 0.25)), 1, 6,
    ColorRGBA(255, 255, 255, 10));
end;

procedure PanelTitle(const R: TRectangle; const Title: string);
begin
  Txt(FontBold, Title, R.x + 16, R.y + 10, 15, C_TEXT2);
end;

function StateColor(S: TStationState): TColor;
begin
  case S of
    ssRunning: Result := C_RUN;
    ssStarved, ssBlocked: Result := C_WAIT;
    ssFault: Result := C_CRIT;
    ssMaint: Result := C_MAINT;
  else
    Result := C_STOP;
  end;
end;

procedure StateIcon(S: TStationState; CX, CY, Size: Single; Blink: Boolean);
var
  h: Single;
  c: TColor;
begin
  h := Size / 2;
  c := StateColor(S);
  case S of
    ssRunning:
      // play triangle
      DrawTriangle(Vec2(CX - h * 0.7, CY - h), Vec2(CX - h * 0.7, CY + h), Vec2(CX + h, CY), c);
    ssStopped:
      DrawRectangle(Round(CX - h * 0.8), Round(CY - h * 0.8), Round(h * 1.6), Round(h * 1.6), c);
    ssStarved, ssBlocked:
      begin
        // pause bars
        DrawRectangle(Round(CX - h * 0.8), Round(CY - h * 0.8), Round(h * 0.55), Round(h * 1.6), c);
        DrawRectangle(Round(CX + h * 0.25), Round(CY - h * 0.8), Round(h * 0.55), Round(h * 1.6), c);
      end;
    ssFault:
      if not Blink then AlarmIcon(apCritical, CX, CY, Size);
    ssMaint:
      begin
        DrawCircle(Round(CX), Round(CY), h, c);
        Txt(FontBold, 'M', CX, CY - h * 0.95, h * 1.6, C_BG, haCenter);
      end;
  end;
end;

function PriorityColor(P: TAlarmPriority): TColor;
begin
  case P of
    apCritical: Result := C_CRIT;
    apHigh: Result := C_HIGH;
  else
    Result := C_MED;
  end;
end;

procedure AlarmIcon(P: TAlarmPriority; CX, CY, Size: Single);
var
  h: Single;
  c: TColor;
  digit: string;
begin
  h := Size / 2;
  c := PriorityColor(P);
  case P of
    apCritical:
      begin
        DrawTriangle(Vec2(CX, CY - h), Vec2(CX - h, CY), Vec2(CX, CY + h), c);
        DrawTriangle(Vec2(CX, CY - h), Vec2(CX, CY + h), Vec2(CX + h, CY), c);
        digit := '1';
      end;
    apHigh:
      begin
        DrawTriangle(Vec2(CX, CY - h), Vec2(CX - h, CY + h * 0.8), Vec2(CX + h, CY + h * 0.8), c);
        digit := '2';
      end;
  else
    begin
      DrawRectangle(Round(CX - h * 0.8), Round(CY - h * 0.8), Round(h * 1.6), Round(h * 1.6), c);
      digit := '3';
    end;
  end;
  // priority number inside the shape (readable without colour)
  Txt(FontBold, digit, CX, CY - h * 0.62 + IfThen(P = apHigh, h * 0.18, 0), h * 1.15, C_BG, haCenter);
end;

procedure MosaicLogo(X, Y, Size: Single);
const
  COLS: array[0..8] of LongWord = ($0B5A86, $3094C8, $06385D, $59096C, $0B5A86, $E2335E,
    $E9E23A, $8BD250, $FA3155);
var
  i: Integer;
  s, g: Single;
  c: LongWord;
begin
  g := Size * 0.06;
  s := (Size - 2 * g) / 3;
  for i := 0 to 8 do
  begin
    c := COLS[i];
    DrawRectangleRounded(Rect(X + (i mod 3) * (s + g), Y + (i div 3) * (s + g), s, s), 0.45, 6,
      ColorRGBA((c shr 16) and $FF, (c shr 8) and $FF, c and $FF));
  end;
end;

end.
