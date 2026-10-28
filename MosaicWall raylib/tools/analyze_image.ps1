<#
  analyze_image.ps1 - measures the mosaic properties described in SPEC_MosaicWallpaper.md §2.

  Usage:
    powershell -ExecutionPolicy Bypass -File tools\analyze_image.ps1 <image.png> <out.json>

  Output (JSON):
    width, height
    bands[20]      per 5 % of height: avg RGB, luminance, gap %, vivid %, hue-class shares
    bottomCols[10] hue-class shares per 10 % of width inside the bottom 20 % (left/right split)
    palette[14]    k-means colours (fixed seed) with share of pixels
    pitchX/pitchY  dominant tile repeat in px (luminance autocorrelation), and as % of width
    edges          share of strong-gradient pixels per zone (outline / detail density)

  Hue classes (HSV): gap (V < 0.12), grey (S < 0.20), blue (170–255°), violet (255–300°),
  magenta (300–345°), red (345–15°), orange (15–48°), yellow (48–75°), green (75–170°).
#>
param([Parameter(Mandatory)][string]$Image, [Parameter(Mandatory)][string]$OutJson)

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -Language CSharp -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Text;
using System.Globalization; using System.Collections.Generic;
public static class MosaicAnalyzer {
  static readonly string[] Classes = {"gap","grey","blue","violet","magenta","red","orange","yellow","green"};
  static int W, H; static byte[] px; static int stride;
  static void Load(string path) {
    using (var bmp0 = new Bitmap(path))
    using (var bmp = bmp0.Clone(new Rectangle(0,0,bmp0.Width,bmp0.Height), PixelFormat.Format24bppRgb)) {
      W = bmp.Width; H = bmp.Height;
      var d = bmp.LockBits(new Rectangle(0,0,W,H), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
      stride = d.Stride; px = new byte[stride*H];
      System.Runtime.InteropServices.Marshal.Copy(d.Scan0, px, 0, px.Length); bmp.UnlockBits(d);
    }
  }
  static void Get(int x,int y,out double r,out double g,out double b){int i=y*stride+x*3; b=px[i]/255.0; g=px[i+1]/255.0; r=px[i+2]/255.0;}
  static double Lum(int x,int y){double r,g,b; Get(x,y,out r,out g,out b); return 0.2126*r+0.7152*g+0.0722*b;}
  static void Hsv(double r,double g,double b,out double h,out double s,out double v){
    double mx=Math.Max(r,Math.Max(g,b)), mn=Math.Min(r,Math.Min(g,b)), d=mx-mn; v=mx; s=mx<=0?0:d/mx; h=0;
    if(d>0){ if(mx==r) h=60*(((g-b)/d)%6); else if(mx==g) h=60*((b-r)/d+2); else h=60*((r-g)/d+4); if(h<0)h+=360; } }
  static int Cls(double r,double g,double b){double h,s,v; Hsv(r,g,b,out h,out s,out v);
    if(v<0.12) return 0; if(s<0.20) return 1;
    if(h>=170&&h<255) return 2; if(h>=255&&h<300) return 3; if(h>=300&&h<345) return 4;
    if(h>=345||h<15) return 5; if(h<48) return 6; if(h<75) return 7; return 8; }
  static string F(double v){return v.ToString("0.###",CultureInfo.InvariantCulture);}
  static string Hex(double r,double g,double b){return string.Format("#{0:X2}{1:X2}{2:X2}",(int)Math.Round(r*255),(int)Math.Round(g*255),(int)Math.Round(b*255));}

  static string ClassObj(double[] c,double n){var sb=new StringBuilder("{");
    for(int k=0;k<Classes.Length;k++){ if(k>0)sb.Append(","); sb.Append("\""+Classes[k]+"\":"+F(100*c[k]/n)); } return sb.Append("}").ToString(); }

  public static string Run(string path) {
    Load(path); var sb=new StringBuilder(); sb.Append("{\"file\":\""+System.IO.Path.GetFileName(path)+"\",\"width\":"+W+",\"height\":"+H+",");
    // ---- bands
    sb.Append("\"bands\":[");
    for(int bnd=0;bnd<20;bnd++){ int y0=bnd*H/20, y1=(bnd+1)*H/20; double sr=0,sg=0,sbb=0,n=0,gap=0,viv=0; var c=new double[9];
      for(int y=y0;y<y1;y+=2) for(int x=0;x<W;x+=2){ double r,g,b; Get(x,y,out r,out g,out b); sr+=r;sg+=g;sbb+=b;n++;
        int k=Cls(r,g,b); c[k]++; if(k==0)gap++; double h,s,v; Hsv(r,g,b,out h,out s,out v); if(s>0.5&&v>0.55)viv++; }
      if(bnd>0)sb.Append(",");
      sb.Append("{\"y0\":"+F(bnd*5)+",\"rgb\":["+F(sr/n*255)+","+F(sg/n*255)+","+F(sbb/n*255)+"],\"hex\":\""+Hex(sr/n,sg/n,sbb/n)+"\",\"lum\":"+F(0.2126*sr/n+0.7152*sg/n+0.0722*sbb/n)+",\"gapPct\":"+F(100*gap/n)+",\"vividPct\":"+F(100*viv/n)+",\"classes\":"+ClassObj(c,n)+"}"); }
    sb.Append("],");
    // ---- bottom 20 %: columns
    sb.Append("\"bottomCols\":[");
    for(int col=0;col<10;col++){ int x0=col*W/10,x1=(col+1)*W/10; var c=new double[9]; double n=0;
      for(int y=H*8/10;y<H;y+=2) for(int x=x0;x<x1;x+=2){double r,g,b; Get(x,y,out r,out g,out b); c[Cls(r,g,b)]++; n++;}
      if(col>0)sb.Append(","); sb.Append("{\"x0\":"+F(col*10)+",\"classes\":"+ClassObj(c,n)+"}"); }
    sb.Append("],");
    // ---- k-means palette (k=14, 40k samples, fixed seed, k-means++)
    var rnd=new Random(653); int N=40000, K=14; var S=new double[N,3];
    for(int i=0;i<N;i++){double r,g,b; Get(rnd.Next(W),rnd.Next(H),out r,out g,out b); S[i,0]=r;S[i,1]=g;S[i,2]=b;}
    var C=new double[K,3]; int f0=rnd.Next(N); for(int j=0;j<3;j++)C[0,j]=S[f0,j];
    var dist=new double[N];
    for(int k=1;k<K;k++){ double tot=0; for(int i=0;i<N;i++){double best=1e9; for(int q=0;q<k;q++){double dd=0; for(int j=0;j<3;j++){double t=S[i,j]-C[q,j]; dd+=t*t;} if(dd<best)best=dd;} dist[i]=best; tot+=best;}
      double pick=rnd.NextDouble()*tot; int sel=0; for(int i=0;i<N;i++){pick-=dist[i]; if(pick<=0){sel=i;break;}} for(int j=0;j<3;j++)C[k,j]=S[sel,j]; }
    var asg=new int[N];
    for(int it=0;it<25;it++){ var sum=new double[K,3]; var cnt=new int[K];
      for(int i=0;i<N;i++){double best=1e9;int bi=0; for(int q=0;q<K;q++){double dd=0; for(int j=0;j<3;j++){double t=S[i,j]-C[q,j]; dd+=t*t;} if(dd<best){best=dd;bi=q;}} asg[i]=bi; cnt[bi]++; for(int j=0;j<3;j++)sum[bi,j]+=S[i,j];}
      for(int q=0;q<K;q++) if(cnt[q]>0) for(int j=0;j<3;j++) C[q,j]=sum[q,j]/cnt[q]; }
    var cntF=new int[K]; var yAvg=new double[K]; rnd=new Random(653);
    // second pass for mean vertical position of each cluster
    for(int i=0;i<N;i++){ int x=rnd.Next(W), y=rnd.Next(H); double r,g,b; Get(x,y,out r,out g,out b);
      double best=1e9;int bi=0; for(int q=0;q<K;q++){double dd=(r-C[q,0])*(r-C[q,0])+(g-C[q,1])*(g-C[q,1])+(b-C[q,2])*(b-C[q,2]); if(dd<best){best=dd;bi=q;}} cntF[bi]++; yAvg[bi]+=(double)y/H; }
    var order=new List<int>(); for(int q=0;q<K;q++)order.Add(q); order.Sort((a,b2)=>cntF[b2].CompareTo(cntF[a]));
    sb.Append("\"palette\":[");
    for(int oi=0;oi<K;oi++){int q=order[oi]; if(oi>0)sb.Append(",");
      sb.Append("{\"hex\":\""+Hex(C[q,0],C[q,1],C[q,2])+"\",\"share\":"+F(100.0*cntF[q]/N)+",\"meanY\":"+F(cntF[q]>0?100*yAvg[q]/cntF[q]:0)+",\"class\":\""+Classes[Cls(C[q,0],C[q,1],C[q,2])]+"\"}");}
    sb.Append("],");
    // ---- tile pitch: luminance autocorrelation (rows/cols in the top 45 %, the regular blue field)
    sb.Append("\"pitchX\":"+F(Pitch(true))+",\"pitchY\":"+F(Pitch(false))+",");
    // ---- edge density per zone (Sobel magnitude > 0.25)
    double[] zb={0,0.45,0.62,0.80,1.0}; sb.Append("\"edges\":[");
    for(int z=0;z<4;z++){ int y0=Math.Max(1,(int)(zb[z]*H)), y1=Math.Min(H-1,(int)(zb[z+1]*H)); double e=0,n=0;
      for(int y=y0;y<y1;y+=2) for(int x=1;x<W-1;x+=2){ double gx=Lum(x+1,y-1)+2*Lum(x+1,y)+Lum(x+1,y+1)-Lum(x-1,y-1)-2*Lum(x-1,y)-Lum(x-1,y+1);
        double gy=Lum(x-1,y+1)+2*Lum(x,y+1)+Lum(x+1,y+1)-Lum(x-1,y-1)-2*Lum(x,y-1)-Lum(x+1,y-1); if(Math.Sqrt(gx*gx+gy*gy)>0.25)e++; n++; }
      if(z>0)sb.Append(","); sb.Append(F(100*e/n)); }
    sb.Append("]}"); return sb.ToString();
  }
  static double Pitch(bool horiz){
    int maxLag=Math.Max(W,H)/6; var ac=new double[maxLag+1]; int lines=0;
    int count = horiz ? (int)(H*0.45) : W;
    for(int li=4; li<count; li+=6){ int len = horiz ? W : (int)(H*0.45); var v=new double[len]; double m=0;
      for(int i=0;i<len;i++){ v[i]= horiz ? Lum(i,li) : Lum(li,i); m+=v[i]; } m/=len; double var0=0; for(int i=0;i<len;i++){v[i]-=m; var0+=v[i]*v[i];} if(var0<=0)continue;
      for(int lag=0;lag<=maxLag;lag++){double s=0; for(int i=0;i+lag<len;i++) s+=v[i]*v[i+lag]; ac[lag]+=s/var0;} lines++; }
    // first local maximum after the first minimum
    int l=1; while(l<maxLag && ac[l+1]<ac[l]) l++; int best=l; for(int k=l;k<maxLag;k++) if(ac[k]>ac[best]) best=k;
    for(int k=l+1;k<maxLag;k++){ if(ac[k]>=ac[k-1]&&ac[k]>=ac[k+1]){best=k;break;} }
    return best; }
}
"@

$json = [MosaicAnalyzer]::Run((Resolve-Path $Image).Path)
$dir = Split-Path -Parent $OutJson
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
[IO.File]::WriteAllText($OutJson, $json)
"analyzed $Image -> $OutJson"
