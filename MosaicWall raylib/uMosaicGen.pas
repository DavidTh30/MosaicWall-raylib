unit uMosaicGen;

{ Builds the tile lists for a given seed and screen size (SPEC §3.2 – §3.5).
  All randomness happens here; the renderer only reads the stored values. }

{$mode objfpc}{$H+}

interface

uses
  uMosaicTypes;

procedure GenerateMosaic(const Cfg: TMosaicConfig; ScreenW, ScreenH: Integer; out M: TMosaic);

implementation

uses
  Math, raylib, uPalette, uNoise;

const
  ACC_GROW = 0.35;

procedure AddTile(var A: TTileArray; var Count: Integer; const T: TTile);
begin
  if Count >= Length(A) then
    SetLength(A, Max(64, Length(A) * 2));
  A[Count] := T;
  Inc(Count);
end;

function NewTile: TTile;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.bridgeTo := -1;
end;

procedure GenerateMosaic(const Cfg: TMosaicConfig; ScreenW, ScreenH: Integer; out M: TMosaic);
var
  cols, rows, i, j, k, d, nb, nHoles, nBase, nAcc: Integer;
  cell, xN, yN, yZ, tint, hole, grow: Single;
  T: TTile;
  vivid: Boolean;
  zc: TColor;
  grid: array of array of Integer;   // accent index per cell, -1 = none
  dirs: array[0..1] of Integer;
begin
  RandSeed := Cfg.Seed;

  M.Width  := ScreenW;
  M.Height := ScreenH;
  cell := Max(12, Round(ScreenW * Cfg.CellRatio));
  M.Cell := cell;
  cols := Ceil(ScreenW / cell) + 2;
  rows := Ceil(ScreenH / cell) + 2;

  M.Holes := nil; M.Base := nil; M.Accent := nil;
  nHoles := 0; nBase := 0; nAcc := 0;

  // --- Layer 1: base blobs (oversized so neighbours overlap; holes leave star-shaped gaps)
  for j := 0 to rows - 1 do
    for i := 0 to cols - 1 do
    begin
      T := NewTile;
      T.cx := i * cell + RandRange(-0.24, 0.24) * cell;
      T.cy := j * cell + RandRange(-0.24, 0.24) * cell;
      T.phase := Random * 2 * Pi;
      // more black gaps around the cool/warm boundary, fewer in the bright bottom bloom
      yN := T.cy / ScreenH;
      hole := Cfg.HoleChance * (1 + Exp(-Sqr((yN - 0.5) / 0.1)));
      // the reference has almost no gaps below the warm boundary (SPEC §2.5: Z2 2.7 %, Z3 1.9 %)
      if yN > 0.62 then hole := hole * 0.2;
      if Random < hole then
      begin
        // dark-blue shading inside the hole so the gap fades instead of a flat black
        T.w := cell * RandRange(0.45, 0.7);
        T.h := cell * RandRange(0.45, 0.7);
        T.roundness := 0.9;
        T.color := WithAlpha(Hex(HEX_BASE_DARK), 170);
        AddTile(M.Holes, nHoles, T);
        Continue;
      end;
      T.w := cell * RandRange(0.95, 1.2);
      T.h := cell * RandRange(0.92, 1.18);
      if yN > 0.62 then
      begin
        // slightly larger blobs in the lower part close the star gaps between neighbours
        T.w := T.w * 1.1;
        T.h := T.h * 1.1;
      end;
      T.roundness := RandRange(0.55, 0.8);
      T.kind := tkBase;
      T.color := ScaleColor(Hex(HEX_BASE), RandRange(0.92, 1.07));
      // lower half: base pieces pick up a muddy tint of the local zone colour
      tint := EnsureRange((yN - 0.55) * 2.2, 0, 0.85);
      if Random < tint then
      begin
        zc := PickZoneColor(T.cx / ScreenW, yN, vivid);
        T.color := LerpColor(T.color, ScaleColor(zc, 0.85), RandRange(0.4, 0.65));
      end;
      T.color2 := T.color;
      AddTile(M.Base, nBase, T);
    end;

  // --- Layer 2: accent tiles
  SetLength(grid, cols, rows);
  for j := 0 to rows - 1 do
    for i := 0 to cols - 1 do
    begin
      grid[i, j] := -1;
      T := NewTile;
      T.cx := i * cell + RandRange(-Cfg.JitterPos, Cfg.JitterPos) * cell;
      T.cy := j * cell + RandRange(-Cfg.JitterPos, Cfg.JitterPos) * cell;
      xN := T.cx / ScreenW;
      yN := T.cy / ScreenH;
      yZ := yN + (Fbm2D(xN * 3 + 5.3, yN * 3 + 1.7) - 0.5) * Cfg.ZoneNoise * 2;
      if Random >= AccentDensity(yZ) then Continue;

      T.w := cell * RandRange(0.72, 0.95);
      T.h := cell * RandRange(0.70, 0.92);
      T.roundness := RandRange(0.40, 0.65);
      // the reference packs the bottom tiles tightly; grow them towards the bottom edge
      // so less dark base shows between them (SPEC §11 R3)
      grow := 1 + ACC_GROW * SmoothStep(0.78, 1.0, yN);
      T.w := T.w * grow;
      T.h := T.h * grow;
      T.color := JitterColor(PickZoneColor(xN, yZ, vivid), 0.06);
      if vivid then T.kind := tkAccent else T.kind := tkBase;
      T.color2 := JitterColor(PickZoneColor(xN, yZ + 0.07, vivid), 0.06);
      T.phase := Random * 2 * Pi;
      if T.kind = tkAccent then
        T.hasGlint := Random < 0.7
      else
        T.hasGlint := Random < 0.25;
      T.glintAngle := DegToRad(RandRange(-55, -25));
      T.glintLen := RandRange(0.25, 0.4);
      T.hasGlow := (T.kind = tkAccent) and (yN > 0.42);
      grid[i, j] := nAcc;
      AddTile(M.Accent, nAcc, T);
    end;

  // --- Bridges: merge neighbouring tiles in the lower part into L / bar shapes
  for j := 0 to rows - 1 do
    for i := 0 to cols - 1 do
    begin
      k := grid[i, j];
      if (k < 0) or M.Accent[k].isMember or (M.Accent[k].bridgeTo >= 0) then Continue;
      // only vivid tiles merge; bridged blue pieces form dark bars the reference doesn't have
      if M.Accent[k].kind <> tkAccent then Continue;
      if (M.Accent[k].cy / ScreenH <= 0.6) or (Random >= Cfg.BridgeChance) then Continue;
      if Random < 0.5 then begin dirs[0] := 0; dirs[1] := 1; end
      else begin dirs[0] := 1; dirs[1] := 0; end;
      for d in dirs do
      begin
        if d = 0 then
        begin
          if i + 1 >= cols then Continue;
          nb := grid[i + 1, j];
        end
        else
        begin
          if j + 1 >= rows then Continue;
          nb := grid[i, j + 1];
        end;
        if (nb < 0) or M.Accent[nb].isMember or (M.Accent[nb].bridgeTo >= 0) then Continue;
        M.Accent[k].bridgeTo := nb;
        M.Accent[nb].isMember := True;
        M.Accent[nb].kind := M.Accent[k].kind;
        M.Accent[nb].color := JitterColor(M.Accent[k].color, 0.03);
        M.Accent[nb].color2 := JitterColor(M.Accent[k].color2, 0.03);
        M.Accent[nb].hasGlow := M.Accent[k].hasGlow;
        Break;
      end;
    end;

  SetLength(M.Holes, nHoles);
  SetLength(M.Base, nBase);
  SetLength(M.Accent, nAcc);
end;

end.
