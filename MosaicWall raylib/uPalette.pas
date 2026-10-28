unit uPalette;

{ Colour palette extracted from the reference image, zone weights and colour helpers
  (SPEC_MosaicWallpaper.md §2). Functions that pick colours use FPC's Random and must
  only be called from the generator, so a seed always yields the same picture. }

{$mode objfpc}{$H+}

interface

uses
  raylib;

const
  // Background / gaps
  HEX_BASE       = $06385D;
  HEX_BASE_DARK  = $021929;
  HEX_GAP        = $040509;
  HEX_GAP2       = $0A0E17;
  // Cool
  HEX_TEAL_BLUE  = $0B5A86;
  HEX_SKY        = $3094C8;
  HEX_STEEL      = $1D6490;
  HEX_ROYAL      = $0631CE;
  HEX_INDIGO     = $1C2894;
  // Transition
  HEX_PURPLE     = $59096C;
  HEX_PLUM       = $88235F;
  HEX_MAGENTA    = $872A61;
  HEX_VIOLET     = $432B77;
  // Warm
  HEX_HOT_PINK   = $E2335E;
  HEX_PINK_RED   = $F4202F;
  HEX_CORAL      = $FA3155;
  HEX_RED        = $E81D0C;
  HEX_ORANGE     = $E3865B;
  HEX_MUSTARD    = $BDBB0E;
  // Fresh
  HEX_YELLOW     = $E9E23A;
  HEX_LIME       = $B3F381;
  HEX_LEAF       = $8BD250;
  HEX_MINT       = $78BD7A;
  HEX_PALE_GREEN = $B0D5B3;

  ZONE_COUNT = 4;   // Z0 Cool, Z1 Transition, Z2 Warm, Z3 Bloom

type
  TZoneWeights = array[0..ZONE_COUNT - 1] of Single;

function Hex(v: LongWord; a: Byte = 255): TColor;
function WithAlpha(c: TColor; a: Byte): TColor;
function ScaleColor(c: TColor; f: Single): TColor;
function Lighten(c: TColor; amount: Single): TColor;
function LerpColor(a, b: TColor; t: Single): TColor;
function JitterColor(c: TColor; amount: Single): TColor;

function SmoothStep(e0, e1, x: Single): Single;
function RandRange(lo, hi: Single): Single;

procedure ZoneWeights(yN: Single; out w: TZoneWeights);
function AccentDensity(yN: Single): Single;
function PickZoneColor(xN, yN: Single; out vivid: Boolean): TColor;

implementation

uses
  uNoise;

type
  TPalEntry = record
    c: LongWord;
    w: Single;
    vivid: Boolean;
  end;

const
  Z0: array[0..4] of TPalEntry = (
    (c: HEX_BASE;      w: 70; vivid: False),
    (c: HEX_TEAL_BLUE; w: 18; vivid: False),
    (c: HEX_SKY;       w: 5;  vivid: True),
    (c: HEX_STEEL;     w: 4;  vivid: False),
    (c: HEX_ROYAL;     w: 3;  vivid: True));

  Z1: array[0..5] of TPalEntry = (
    (c: HEX_BASE;      w: 50; vivid: False),
    (c: HEX_TEAL_BLUE; w: 12; vivid: False),
    (c: HEX_PURPLE;    w: 10; vivid: True),
    (c: HEX_ROYAL;     w: 8;  vivid: True),
    (c: HEX_HOT_PINK;  w: 10; vivid: True),
    (c: HEX_RED;       w: 10; vivid: True));

  Z2: array[0..6] of TPalEntry = (
    (c: HEX_BASE;      w: 30; vivid: False),
    (c: HEX_PLUM;      w: 15; vivid: True),
    (c: HEX_MAGENTA;   w: 15; vivid: True),
    (c: HEX_HOT_PINK;  w: 15; vivid: True),
    (c: HEX_CORAL;     w: 10; vivid: True),
    (c: HEX_VIOLET;    w: 8;  vivid: True),
    (c: HEX_MUSTARD;   w: 7;  vivid: True));

  // Z3 keeps a few light-blue pieces: the reference still has 15–44 % blue at 80–100 % height
  Z3Left: array[0..5] of TPalEntry = (
    (c: HEX_TEAL_BLUE; w: 10; vivid: False),
    (c: HEX_CORAL;     w: 22; vivid: True),
    (c: HEX_PINK_RED;  w: 22; vivid: True),
    (c: HEX_RED;       w: 18; vivid: True),
    (c: HEX_ORANGE;    w: 18; vivid: True),
    (c: HEX_MAGENTA;   w: 20; vivid: True));

  Z3Right: array[0..6] of TPalEntry = (
    (c: HEX_TEAL_BLUE;  w: 10; vivid: False),
    (c: HEX_YELLOW;     w: 18; vivid: True),
    (c: HEX_LIME;       w: 20; vivid: True),
    (c: HEX_LEAF;       w: 20; vivid: True),
    (c: HEX_MINT;       w: 16; vivid: True),
    (c: HEX_PALE_GREEN; w: 12; vivid: True),
    (c: HEX_MUSTARD;    w: 14; vivid: True));

  ZONE_EDGE: array[0..2] of Single = (0.45, 0.62, 0.80);
  ZONE_SOFT = 0.06;

function ClampB(v: Single): Byte; inline;
begin
  if v <= 0 then Result := 0
  else if v >= 255 then Result := 255
  else Result := Round(v);
end;

function Hex(v: LongWord; a: Byte): TColor;
begin
  Result.r := (v shr 16) and $FF;
  Result.g := (v shr 8) and $FF;
  Result.b := v and $FF;
  Result.a := a;
end;

function WithAlpha(c: TColor; a: Byte): TColor;
begin
  Result := c;
  Result.a := a;
end;

function ScaleColor(c: TColor; f: Single): TColor;
begin
  Result.r := ClampB(c.r * f);
  Result.g := ClampB(c.g * f);
  Result.b := ClampB(c.b * f);
  Result.a := c.a;
end;

function Lighten(c: TColor; amount: Single): TColor;
begin
  Result.r := ClampB(c.r + (255 - c.r) * amount);
  Result.g := ClampB(c.g + (255 - c.g) * amount);
  Result.b := ClampB(c.b + (255 - c.b) * amount);
  Result.a := c.a;
end;

function LerpColor(a, b: TColor; t: Single): TColor;
begin
  Result.r := ClampB(a.r + (b.r - a.r) * t);
  Result.g := ClampB(a.g + (b.g - a.g) * t);
  Result.b := ClampB(a.b + (b.b - a.b) * t);
  Result.a := ClampB(a.a + (b.a - a.a) * t);
end;

function JitterColor(c: TColor; amount: Single): TColor;
var
  f: Single;
begin
  // brightness jitter plus a small per-channel shift for a slight hue wobble
  f := 1 + RandRange(-amount, amount);
  Result.r := ClampB(c.r * f + RandRange(-6, 6));
  Result.g := ClampB(c.g * f + RandRange(-6, 6));
  Result.b := ClampB(c.b * f + RandRange(-6, 6));
  Result.a := c.a;
end;

function SmoothStep(e0, e1, x: Single): Single;
var
  t: Single;
begin
  t := (x - e0) / (e1 - e0);
  if t < 0 then t := 0 else if t > 1 then t := 1;
  Result := t * t * (3 - 2 * t);
end;

function RandRange(lo, hi: Single): Single;
begin
  Result := lo + Random * (hi - lo);
end;

procedure ZoneWeights(yN: Single; out w: TZoneWeights);
var
  s: array[0..2] of Single;
  i: Integer;
begin
  for i := 0 to 2 do
    s[i] := SmoothStep(ZONE_EDGE[i] - ZONE_SOFT, ZONE_EDGE[i] + ZONE_SOFT, yN);
  w[0] := 1 - s[0];
  w[1] := s[0] - s[1];
  w[2] := s[1] - s[2];
  w[3] := s[2];
end;

function AccentDensity(yN: Single): Single;
var
  w: TZoneWeights;
begin
  ZoneWeights(yN, w);
  Result := w[0] * 0.25 + w[1] * 0.42 + w[2] * 0.72 + w[3] * 0.98;
end;

function PickFrom(const P: array of TPalEntry; out vivid: Boolean): TColor;
var
  i: Integer;
  total, r: Single;
begin
  total := 0;
  for i := 0 to High(P) do total := total + P[i].w;
  r := Random * total;
  for i := 0 to High(P) do
  begin
    r := r - P[i].w;
    if (r <= 0) or (i = High(P)) then
    begin
      vivid := P[i].vivid;
      Exit(Hex(P[i].c));
    end;
  end;
  vivid := False;
  Result := Hex(HEX_BASE);
end;

function PickZoneColor(xN, yN: Single; out vivid: Boolean): TColor;
var
  w: TZoneWeights;
  r, side: Single;
  z: Integer;
begin
  ZoneWeights(yN, w);
  r := Random;
  z := 0;
  while (z < ZONE_COUNT - 1) and (r > w[z]) do
  begin
    r := r - w[z];
    Inc(z);
  end;
  case z of
    0: Result := PickFrom(Z0, vivid);
    1: Result := PickFrom(Z1, vivid);
    2: Result := PickFrom(Z2, vivid);
  else
    begin
      // bottom bloom: red/pink on the left, yellow/green on the right, soft noisy border
      side := SmoothStep(0.36, 0.62, xN + (ValueNoise2D(xN * 4 + 17, yN * 4) - 0.5) * 0.25);
      if Random < side then
        Result := PickFrom(Z3Right, vivid)
      else
        Result := PickFrom(Z3Left, vivid);
    end;
  end;
end;

end.
