unit uNoise;

{ Light-weight deterministic 2D value noise (no global state). }

{$mode objfpc}{$H+}

interface

function ValueNoise2D(x, y: Single): Single;   // 0..1
function Fbm2D(x, y: Single; octaves: Integer = 3): Single;  // 0..1

implementation

function Hash2(ix, iy: LongInt): Single;
var
  h: LongWord;
begin
  {$push}{$R-}{$Q-}
  h := LongWord(ix) * 374761393 + LongWord(iy) * 668265263;
  h := (h xor (h shr 13)) * 1274126177;
  h := h xor (h shr 16);
  {$pop}
  Result := (h and $FFFFFF) / $FFFFFF;
end;

function Smooth(t: Single): Single; inline;
begin
  Result := t * t * (3 - 2 * t);
end;

function ValueNoise2D(x, y: Single): Single;
var
  ix, iy: LongInt;
  fx, fy, a, b, c, d: Single;
begin
  ix := Trunc(x); if x < ix then Dec(ix);
  iy := Trunc(y); if y < iy then Dec(iy);
  fx := Smooth(x - ix);
  fy := Smooth(y - iy);
  a := Hash2(ix, iy);
  b := Hash2(ix + 1, iy);
  c := Hash2(ix, iy + 1);
  d := Hash2(ix + 1, iy + 1);
  Result := (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy;
end;

function Fbm2D(x, y: Single; octaves: Integer): Single;
var
  i: Integer;
  amp, sum, norm: Single;
begin
  amp := 1; sum := 0; norm := 0;
  for i := 1 to octaves do
  begin
    sum := sum + ValueNoise2D(x, y) * amp;
    norm := norm + amp;
    amp := amp * 0.5;
    x := x * 2.03; y := y * 2.03;
  end;
  Result := sum / norm;
end;

end.
