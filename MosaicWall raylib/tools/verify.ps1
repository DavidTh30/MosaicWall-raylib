<#
  verify.ps1 - acceptance checks for MosaicWall (SPEC_MosaicWallpaper.md §10).
  Run from the project folder after building MosaicWall.exe:

    powershell -ExecutionPolicy Bypass -File tools\verify.ps1 [-Cell 0.085]

  -Cell passes --cell to every run, to test a cell ratio before changing the default.

  1. Colour match (R11): average colour of 7 horizontal bands (+/-3 % of height) vs the reference image,
     over 16 fixed seeds. One seed alone swings by up to ~30 per channel because a band holds only about
     one row of tiles, so the check separates systematic error from per-seed scatter:
       a. bias   - mean signed difference over the seeds, every band and channel within +/-15
       b. median - median of the per-seed worst difference <= 25 (the old single-seed limit)
       c. max    - no seed worse than 40 (no individual wallpaper badly off)
  2. Determinism: the same seed renders a byte-identical PNG twice.
  3. Speed: off-screen bench at 1080x1920, glow 0 / 1 / 2. Pass = >= 60 FPS.
  4. Motion: share of pixels that change by > 12/255 between t = 0 and t = 0.5 s (motion 100 %).
#>
param([string]$Cell = '')
$ErrorActionPreference = 'Stop'
$xa = @(); if ($Cell) { $xa = @('--cell', $Cell) }
$root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $root 'MosaicWall.exe'
$ref  = Join-Path $root '0653bb4e017433b0c1e6c135a6e6d4a9.png'
$tmp  = Join-Path ([IO.Path]::GetTempPath()) 'mosaic_verify'
New-Item -ItemType Directory -Force $tmp | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -Language CSharp -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging;
public static class Verify {
  static byte[] Load(string p, out int w, out int h, out int stride) {
    using (var b0 = new Bitmap(p)) using (var b = b0.Clone(new Rectangle(0,0,b0.Width,b0.Height), PixelFormat.Format24bppRgb)) {
      w = b.Width; h = b.Height; var d = b.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
      stride = d.Stride; var px = new byte[stride*h]; System.Runtime.InteropServices.Marshal.Copy(d.Scan0, px, 0, px.Length); b.UnlockBits(d); return px; } }
  // mean RGB of the band fy +/- 0.03
  public static double[] Band(string p, double fy) { int w,h,s; var px = Load(p, out w, out h, out s);
    int y0 = (int)((fy-0.03)*h), y1 = (int)((fy+0.03)*h); double r=0,g=0,b=0,n=0;
    for (int y=y0; y<=y1; y+=2) for (int x=0; x<w; x+=2) { int i=y*s+x*3; b+=px[i]; g+=px[i+1]; r+=px[i+2]; n++; }
    return new double[]{r/n,g/n,b/n}; }
  public static double Changed(string a, string c) { int w,h,s,w2,h2,s2; var A = Load(a, out w, out h, out s); var B = Load(c, out w2, out h2, out s2);
    double ch=0, n=0; for (int y=0; y<h; y+=2) for (int x=0; x<w; x+=2) { int i=y*s+x*3;
      double d = (Math.Abs(A[i]-B[i]) + Math.Abs(A[i+1]-B[i+1]) + Math.Abs(A[i+2]-B[i+2])) / 3.0; if (d > 12) ch++; n++; }
    return 100*ch/n; }
}
"@

$rows = 0.1, 0.3, 0.5, 0.6, 0.7, 0.8, 0.9
$refBands = @{}; foreach ($fy in $rows) { $refBands[$fy] = [Verify]::Band($ref, $fy) }
$allPass = $true

"## 1. Colour match, 16 seeds (band +/-3 %; bias <= 15, median worst <= 25, max worst <= 40)"
if ($Cell) { "cell ratio $Cell" }
$seeds = 653, 77, 1234, 9, 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13, 14
$sum = @{}; foreach ($fy in $rows) { $sum[$fy] = @(0.0, 0.0, 0.0) }
$worsts = @()
foreach ($seed in $seeds) {
  $f = Join-Path $tmp "seed_$seed.png"
  & $exe --shot $f --render 1080x1920 --seed $seed @xa | Out-Null
  $worst = 0
  foreach ($fy in $rows) {
    $b = [Verify]::Band($f, $fy); $r = $refBands[$fy]
    for ($c = 0; $c -lt 3; $c++) { $d = $b[$c] - $r[$c]; $sum[$fy][$c] += $d; $worst = [Math]::Max($worst, [Math]::Abs($d)) }
  }
  $worsts += $worst
}
$n = $seeds.Count
"per-seed worst: " + (($worsts | ForEach-Object { '{0:N0}' -f $_ }) -join ' ')
$maxBias = 0; $biasTxt = @()
foreach ($fy in $rows) {
  $m = $sum[$fy] | ForEach-Object { $_ / $n }
  $maxBias = [Math]::Max($maxBias, ($m | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum)
  $biasTxt += ('{0:N1}: {1:+0;-0}/{2:+0;-0}/{3:+0;-0}' -f $fy, $m[0], $m[1], $m[2])
}
"bias R/G/B per band: " + ($biasTxt -join '  ')
$sorted = $worsts | Sort-Object
$median = ($sorted[[int]($n / 2) - 1] + $sorted[[int]($n / 2)]) / 2
$maxWorst = ($worsts | Measure-Object -Maximum).Maximum
foreach ($t in @(@('bias', $maxBias, 15), @('median worst', $median, 25), @('max worst', $maxWorst, 40))) {
  $ok = $t[1] -le $t[2]; if (-not $ok) { $allPass = $false }
  "{0,-13} {1,5:N1}  (limit {2})  {3}" -f $t[0], $t[1], $t[2], $(if ($ok) {'PASS'} else {'FAIL'})
}

"## 2. Determinism"
$a = Join-Path $tmp 'det_a.png'; $b2 = Join-Path $tmp 'det_b.png'
& $exe --shot $a --render 1080x1920 --seed 653 @xa | Out-Null
& $exe --shot $b2 --render 1080x1920 --seed 653 @xa | Out-Null
$same = (Get-FileHash $a).Hash -eq (Get-FileHash $b2).Hash
if (-not $same) { $allPass = $false }
"seed 653 rendered twice: " + $(if ($same) {'identical PASS'} else {'DIFFERENT FAIL'})

"## 3. Speed (off-screen 1080x1920, 120 frames)"
foreach ($g in 0, 1, 2) {
  $line = (& $exe --bench 120 --glow $g @xa | Out-String).Trim()
  $fps = [double]([regex]::Match($line, '\(([\d.]+) FPS\)').Groups[1].Value)
  if ($fps -lt 60) { $allPass = $false }
  "$line  " + $(if ($fps -ge 60) {'PASS'} else {'FAIL'})
}

"## 4. Motion (pixels changed > 12/255 between t=0 and t=0.5 s)"
foreach ($m in 0, 100, 200) {
  $t0 = Join-Path $tmp "m${m}_0.png"; $t1 = Join-Path $tmp "m${m}_1.png"
  & $exe --shot $t0 --render 540x960 --time 0 --motion $m @xa | Out-Null
  & $exe --shot $t1 --render 540x960 --time 0.5 --motion $m @xa | Out-Null
  "motion {0,3} %: {1,5:N1} % of pixels changed" -f $m, [Verify]::Changed($t0, $t1)
}

""
if ($allPass) { "RESULT: ALL PASS" } else { "RESULT: SOME CHECKS FAILED" }
