unit uMosaicRender;

{ Draws a generated mosaic (SPEC §3.1, §3.6, §3.7, §4).
  Usage per frame:
    R.PrepareGlow(M, Cfg, t);     // outside any BeginTextureMode (glow mode 2 renders into its own RT)
    <BeginDrawing or BeginTextureMode>
    R.DrawScene(M, Cfg, t);
    <End...> }

{$mode objfpc}{$H+}

interface

uses
  raylib, uMosaicTypes;

type
  TMosaicRenderer = class
  private
    FGlowTex: TTexture2D;       // white radial gradient, tinted per tile
    FVigTex: TTexture2D;        // black vignette mask
    FGlowRT: TRenderTexture2D;  // low-res glow buffer (mode 2)
    FGlowW, FGlowH: Integer;
    FPrims, FGlowPrims: Integer;   // draw calls issued by the last DrawScene / PrepareGlow
    function Wave(const T: TTile; time, cell: Single): Single;
    function TileRect(const T: TTile; const Cfg: TMosaicConfig; time, amp, drift, cell: Single): TRectangle;
    function TileColor(const T: TTile; const Cfg: TMosaicConfig; time, H, cell: Single): TColor;
    function BridgeRect(const A, B: TRectangle): TRectangle;
    procedure DrawGlowSprite(const r: TRectangle; c: TColor; alpha: Byte; scale: Single);
    function GlowAlpha(const T: TTile; const Cfg: TMosaicConfig; time, cell: Single; base: Integer): Byte;
    procedure DrawAccentGroup(const M: TMosaic; const Cfg: TMosaicConfig; idx: Integer; time: Single);
    procedure EnsureGlowRT(W, H: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure PrepareGlow(const M: TMosaic; const Cfg: TMosaicConfig; time: Single);
    procedure DrawScene(const M: TMosaic; const Cfg: TMosaicConfig; time: Single);
    function GpuBytes: Int64;          // textures + glow RT owned by the renderer
    property Prims: Integer read FPrims;
    property GlowPrims: Integer read FGlowPrims;
    property GlowW: Integer read FGlowW;
    property GlowH: Integer read FGlowH;
  end;

procedure DrawRenderTexture(const RT: TRenderTexture2D; W, H: Integer; tint: TColor);
procedure DrawSceneTexture(const RT: TRenderTexture2D; W, H: Integer; opacity: Single);

implementation

uses
  Math, uPalette;

const
  SEGMENTS = 7;

procedure DrawRenderTexture(const RT: TRenderTexture2D; W, H: Integer; tint: TColor);
begin
  // render textures are stored upside down in OpenGL: flip with a negative source height
  DrawTexturePro(RT.texture, Rect(0, 0, RT.texture.width, -RT.texture.height),
    Rect(0, 0, W, H), Vec2(0, 0), 0, tint);
end;

procedure DrawSceneTexture(const RT: TRenderTexture2D; W, H: Integer; opacity: Single);
var
  k: Byte;
begin
  // A baked scene already holds final RGB, but translucent shapes lowered its alpha channel.
  // Premultiplied blending ignores that alpha for the colour, so the copy matches the live scene.
  k := Round(EnsureRange(opacity, 0, 1) * 255);
  BeginBlendMode(BLEND_ALPHA_PREMULTIPLY);
  DrawRenderTexture(RT, W, H, ColorRGBA(k, k, k, k));
  EndBlendMode;
end;

function MakeMaskTexture(size: Integer; vignette: Boolean): TTexture2D;
var
  img: TImage;
  px: PByte;
  x, y: Integer;
  dx, dy, r, a: Single;
begin
  if vignette then img := GenImageColor(size, size, BLACK)
  else img := GenImageColor(size, size, WHITE);
  px := PByte(img.data);   // R8G8B8A8
  for y := 0 to size - 1 do
    for x := 0 to size - 1 do
    begin
      dx := (x + 0.5) / size * 2 - 1;
      dy := (y + 0.5) / size * 2 - 1;
      r := Sqrt(dx * dx + dy * dy);
      if vignette then
        a := SmoothStep(0.45, 1.35, r)
      else
      begin
        a := 1 - EnsureRange(r, 0, 1);
        a := a * a;
      end;
      px[(y * size + x) * 4 + 3] := Round(EnsureRange(a, 0, 1) * 255);
    end;
  Result := LoadTextureFromImage(img);
  UnloadImage(img);
  SetTextureFilter(Result, TEXTURE_FILTER_BILINEAR);
end;

constructor TMosaicRenderer.Create;
begin
  inherited Create;
  FGlowTex := MakeMaskTexture(64, False);
  FVigTex := MakeMaskTexture(128, True);
  FGlowW := 0; FGlowH := 0;
end;

destructor TMosaicRenderer.Destroy;
begin
  UnloadTexture(FGlowTex);
  UnloadTexture(FVigTex);
  if FGlowW > 0 then UnloadRenderTexture(FGlowRT);
  inherited Destroy;
end;

procedure TMosaicRenderer.EnsureGlowRT(W, H: Integer);
begin
  W := Max(1, W div 4);
  H := Max(1, H div 4);
  if (W = FGlowW) and (H = FGlowH) then Exit;
  if FGlowW > 0 then UnloadRenderTexture(FGlowRT);
  FGlowRT := LoadRenderTexture(W, H);
  SetTextureFilter(FGlowRT.texture, TEXTURE_FILTER_BILINEAR);
  FGlowW := W; FGlowH := H;
end;

// Diagonal wave travelling down-right across the mosaic, -1..1. Wavelength ~7 cells,
// one crest every ~4 s: the part of the motion you notice at a glance.
function TMosaicRenderer.Wave(const T: TTile; time, cell: Single): Single;
begin
  Result := Sin(time * 1.6 - (T.cx + T.cy * 0.8) / cell * 0.9);
end;

// amp / drift are fractions of the tile size / cell at Motion = 1
function TMosaicRenderer.TileRect(const T: TTile; const Cfg: TMosaicConfig;
  time, amp, drift, cell: Single): TRectangle;
var
  s, dx, dy, w, h, m: Single;
begin
  s := 1; dx := 0; dy := 0;
  m := Cfg.Motion;
  if Cfg.Animate and (m > 0) then
  begin
    // own breathing (per-tile phase) + the shared travelling wave
    s := 1 + m * amp * (Sin(time * 1.6 + T.phase) + 0.8 * Wave(T, time, cell));
    if s < 0.3 then s := 0.3;
    dx := m * drift * cell * Sin(time * 0.9 + T.phase * 1.3);
    dy := m * drift * cell * Cos(time * 0.7 + T.phase);
  end;
  w := T.w * s;
  h := T.h * s;
  Result := Rect(T.cx + dx - w / 2, T.cy + dy - h / 2, w, h);
end;

function TMosaicRenderer.TileColor(const T: TTile; const Cfg: TMosaicConfig; time, H, cell: Single): TColor;
var
  k: Single;
begin
  Result := T.color;
  if Cfg.GradientScroll then
  begin
    // wave travelling down the screen, blending each tile towards its alternate colour
    k := 0.5 + 0.5 * Sin(time * 0.6 - (T.cy / H) * 4);
    Result := LerpColor(T.color, T.color2, k);
  end;
  if Cfg.Animate and (Cfg.Motion > 0) then
    // twinkle (per tile) + brighter crest of the travelling wave
    Result := ScaleColor(Result, 1 + Cfg.Motion *
      (0.08 * Sin(time * 2.0 + T.phase) + 0.12 * Wave(T, time, cell)));
end;

function TMosaicRenderer.BridgeRect(const A, B: TRectangle): TRectangle;
var
  ax, ay, bx, by, th: Single;
begin
  ax := A.x + A.width / 2;  ay := A.y + A.height / 2;
  bx := B.x + B.width / 2;  by := B.y + B.height / 2;
  if Abs(bx - ax) >= Abs(by - ay) then
  begin
    th := Min(A.height, B.height) * 0.9;
    Result := Rect(Min(ax, bx), (ay + by) / 2 - th / 2, Abs(bx - ax), th);
  end
  else
  begin
    th := Min(A.width, B.width) * 0.9;
    Result := Rect((ax + bx) / 2 - th / 2, Min(ay, by), th, Abs(by - ay));
  end;
end;

function Expand(const r: TRectangle; e: Single): TRectangle; inline;
begin
  Result := Rect(r.x - e, r.y - e, r.width + 2 * e, r.height + 2 * e);
end;

// glow swells as the wave crest passes over the tile
function TMosaicRenderer.GlowAlpha(const T: TTile; const Cfg: TMosaicConfig; time, cell: Single;
  base: Integer): Byte;
var
  a: Single;
begin
  a := base;
  if Cfg.Animate then
    a := base * (1 + 0.6 * Cfg.Motion * Wave(T, time, cell));
  Result := Round(EnsureRange(a, 0, 255));
end;

procedure TMosaicRenderer.DrawGlowSprite(const r: TRectangle; c: TColor; alpha: Byte; scale: Single);
var
  cx, cy, s: Single;
begin
  cx := r.x + r.width / 2;
  cy := r.y + r.height / 2;
  s := Max(r.width, r.height) * scale;
  Inc(FPrims);
  DrawTexturePro(FGlowTex, Rect(0, 0, FGlowTex.width, FGlowTex.height),
    Rect(cx - s / 2, cy - s / 2, s, s), Vec2(0, 0), 0, WithAlpha(c, alpha));
end;

procedure TMosaicRenderer.DrawAccentGroup(const M: TMosaic; const Cfg: TMosaicConfig;
  idx: Integer; time: Single);
var
  members: array[0..1] of Integer;
  rects: array[0..2] of TRectangle;
  cols: array[0..1] of TColor;
  n, i: Integer;
  T: TTile;
  r, sh: TRectangle;
  edge, gx, gy, gl: Single;
  edgeCol: TColor;
  edgeA, shadeA: Byte;
  amp, drift: Single;
begin
  amp := 0.06;
  drift := 0.10;
  members[0] := idx;
  n := 1;
  if M.Accent[idx].bridgeTo >= 0 then
  begin
    members[1] := M.Accent[idx].bridgeTo;
    n := 2;
  end;
  for i := 0 to n - 1 do
  begin
    rects[i] := TileRect(M.Accent[members[i]], Cfg, time, amp, drift, M.Cell);
    cols[i] := TileColor(M.Accent[members[i]], Cfg, time, M.Height, M.Cell);
  end;
  if n = 2 then rects[2] := BridgeRect(rects[0], rects[1]);

  T := M.Accent[idx];
  if T.kind = tkAccent then
  begin
    edgeA := 215; shadeA := 150;
  end
  else
  begin
    edgeA := 120; shadeA := 70;
  end;
  edge := Max(1.2, M.Cell * 0.035);

  // dark rim (expanded silhouette) for all parts, then fills — merged pieces share one outline
  for i := 0 to n - 1 do
  begin
    edgeCol := WithAlpha(ScaleColor(cols[i], 0.22), edgeA);
    DrawRectangleRounded(Expand(rects[i], edge), M.Accent[members[i]].roundness, SEGMENTS, edgeCol);
  end;
  Inc(FPrims, 2 * n + 2 * Ord(n = 2));   // rims + fills (+ bridge rim and fill)
  if n = 2 then
    DrawRectangleRounded(Expand(rects[2], edge), 0.5, SEGMENTS,
      WithAlpha(ScaleColor(cols[0], 0.22), edgeA));
  for i := 0 to n - 1 do
    DrawRectangleRounded(rects[i], M.Accent[members[i]].roundness, SEGMENTS, cols[i]);
  if n = 2 then
    DrawRectangleRounded(rects[2], 0.5, SEGMENTS, LerpColor(cols[0], cols[1], 0.5));

  // inner shade + glint
  for i := 0 to n - 1 do
  begin
    T := M.Accent[members[i]];
    r := rects[i];
    sh := Rect(r.x + r.width * 0.10, r.y + r.height * 0.10, r.width * 0.68, r.height * 0.62);
    DrawRectangleRounded(sh, Min(1, T.roundness + 0.15), SEGMENTS,
      WithAlpha(Lighten(cols[i], 0.13), shadeA));
    Inc(FPrims);
    if T.hasGlint then
    begin
      // soft light smudge plus a faint streak, like the painted reflections in the reference
      gx := r.x + r.width * 0.36;
      gy := r.y + r.height * 0.34;
      DrawGlowSprite(Rect(gx - r.width * 0.2, gy - r.height * 0.2, r.width * 0.4, r.height * 0.4),
        WHITE, IfThen(T.kind = tkAccent, 70, 30), 1.0);
      gl := r.width * T.glintLen * 0.5;
      Inc(FPrims);
      DrawLineEx(Vec2(gx - Cos(T.glintAngle) * gl, gy - Sin(T.glintAngle) * gl),
        Vec2(gx + Cos(T.glintAngle) * gl, gy + Sin(T.glintAngle) * gl),
        Max(1.0, r.width * 0.035), ColorRGBA(255, 255, 255, IfThen(T.kind = tkAccent, 38, 18)));
    end;
  end;
end;

procedure TMosaicRenderer.PrepareGlow(const M: TMosaic; const Cfg: TMosaicConfig; time: Single);
var
  i: Integer;
  r: TRectangle;
begin
  FGlowPrims := 0;
  if Cfg.GlowMode < 2 then Exit;
  EnsureGlowRT(M.Width, M.Height);
  FPrims := 0;
  BeginTextureMode(FGlowRT);
  ClearBackground(ColorRGBA(0, 0, 0, 0));
  BeginBlendMode(BLEND_ADDITIVE);
  for i := 0 to High(M.Accent) do
    if M.Accent[i].hasGlow then
    begin
      r := TileRect(M.Accent[i], Cfg, time, 0.06, 0.10, M.Cell);
      r := Rect(r.x / 4, r.y / 4, r.width / 4, r.height / 4);
      DrawGlowSprite(r, TileColor(M.Accent[i], Cfg, time, M.Height, M.Cell), GlowAlpha(M.Accent[i], Cfg, time, M.Cell, 200), 3.2);
    end;
  EndBlendMode;
  EndTextureMode;
  FGlowPrims := FPrims;
end;

function TMosaicRenderer.GpuBytes: Int64;
begin
  Result := Int64(FGlowTex.width) * FGlowTex.height * 4 + Int64(FVigTex.width) * FVigTex.height * 4;
  if FGlowW > 0 then
    Result := Result + Int64(FGlowW) * FGlowH * 8;   // colour + depth attachment
end;

procedure TMosaicRenderer.DrawScene(const M: TMosaic; const Cfg: TMosaicConfig; time: Single);
var
  i: Integer;
  r: TRectangle;
  off: Single;
begin
  FPrims := 0;
  ClearBackground(Hex(HEX_GAP));
  Inc(FPrims, Length(M.Holes) + Length(M.Base) + Length(M.Accent));   // holes, base blobs, shadows

  // gap shading
  for i := 0 to High(M.Holes) do
    DrawRectangleRounded(TileRect(M.Holes[i], Cfg, time, 0, 0, M.Cell), M.Holes[i].roundness, SEGMENTS,
      M.Holes[i].color);

  // base blobs (gentle breathing keeps the gaps alive)
  for i := 0 to High(M.Base) do
    DrawRectangleRounded(TileRect(M.Base[i], Cfg, time, 0.025, 0.04, M.Cell),
      M.Base[i].roundness, SEGMENTS, M.Base[i].color);

  // glow under vivid tiles
  if Cfg.GlowMode >= 1 then
  begin
    BeginBlendMode(BLEND_ADDITIVE);
    for i := 0 to High(M.Accent) do
      if M.Accent[i].hasGlow then
        DrawGlowSprite(TileRect(M.Accent[i], Cfg, time, 0.06, 0.10, M.Cell),
          TileColor(M.Accent[i], Cfg, time, M.Height, M.Cell),
          GlowAlpha(M.Accent[i], Cfg, time, M.Cell, 60), 2.4);
    EndBlendMode;
  end;

  // drop shadows of all accent tiles
  off := M.Cell * 0.05;
  for i := 0 to High(M.Accent) do
  begin
    r := TileRect(M.Accent[i], Cfg, time, 0.06, 0.10, M.Cell);
    r.x := r.x + off * 0.8;
    r.y := r.y + off;
    DrawRectangleRounded(r, M.Accent[i].roundness, SEGMENTS, ColorRGBA(0, 0, 0, 90));
  end;

  // accent tiles, top to bottom; bridged partners are drawn together with their owner
  for i := 0 to High(M.Accent) do
    if not M.Accent[i].isMember then
      DrawAccentGroup(M, Cfg, i, time);

  // soft colour bleed (mode 2)
  if (Cfg.GlowMode >= 2) and (FGlowW > 0) then
  begin
    BeginBlendMode(BLEND_ADDITIVE);
    DrawRenderTexture(FGlowRT, M.Width, M.Height, ColorRGBA(255, 255, 255, 90));
    EndBlendMode;
    Inc(FPrims);
  end;

  if Cfg.Vignette > 0 then Inc(FPrims);
  if Cfg.Dim then Inc(FPrims);
  if Cfg.Vignette > 0 then
    DrawTexturePro(FVigTex, Rect(0, 0, FVigTex.width, FVigTex.height),
      Rect(0, 0, M.Width, M.Height), Vec2(0, 0), 0,
      ColorRGBA(255, 255, 255, Round(EnsureRange(Cfg.Vignette, 0, 1) * 255)));

  if Cfg.Dim then
    DrawRectangle(0, 0, M.Width, M.Height, ColorRGBA(0, 0, 0, 40));
end;

end.
