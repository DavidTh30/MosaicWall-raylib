unit uSysInfo;

{ Process / system information for the developer status window (Windows). }

{$mode objfpc}{$H+}

interface

type
  TProcessMem = record
    WorkingSetMB, PeakWorkingSetMB, PrivateMB: Double;
  end;

function GetProcessMem: TProcessMem;
function FileInfoText(const Path: string): string;   // "size KB, modified yyyy-mm-dd hh:nn"
function OSVersionText: string;
function CpuCount: Integer;
function BuildInfoText: string;                       // compiler + build date of this exe

// Reads OpenGL strings; must be called on the thread that owns a current GL context.
procedure ReadGLStrings(out Vendor, Renderer, Version: string);

implementation

uses
  Windows, SysUtils, Classes;

type
  TProcessMemoryCountersEx = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize: PtrUInt;
    WorkingSetSize: PtrUInt;
    QuotaPeakPagedPoolUsage: PtrUInt;
    QuotaPagedPoolUsage: PtrUInt;
    QuotaPeakNonPagedPoolUsage: PtrUInt;
    QuotaNonPagedPoolUsage: PtrUInt;
    PagefileUsage: PtrUInt;
    PeakPagefileUsage: PtrUInt;
    PrivateUsage: PtrUInt;
  end;

function GetProcessMemoryInfo(Process: THandle; Counters: Pointer; cb: DWORD): BOOL;
  stdcall; external 'psapi.dll';
function glGetString(name: Cardinal): PAnsiChar; stdcall; external 'opengl32.dll';

const
  GL_VENDOR   = $1F00;
  GL_RENDERER = $1F01;
  GL_VERSION  = $1F02;

function GetProcessMem: TProcessMem;
var
  c: TProcessMemoryCountersEx;
begin
  FillChar(Result, SizeOf(Result), 0);
  FillChar(c, SizeOf(c), 0);
  c.cb := SizeOf(c);
  if GetProcessMemoryInfo(GetCurrentProcess, @c, c.cb) then
  begin
    Result.WorkingSetMB := c.WorkingSetSize / (1024 * 1024);
    Result.PeakWorkingSetMB := c.PeakWorkingSetSize / (1024 * 1024);
    Result.PrivateMB := c.PrivateUsage / (1024 * 1024);
  end;
end;

function FileInfoText(const Path: string): string;
var
  sr: TSearchRec;
begin
  if FindFirst(Path, faAnyFile, sr) = 0 then
  begin
    Result := Format('%d KB, modified %s',
      [sr.Size div 1024, FormatDateTime('yyyy-mm-dd hh:nn', FileDateToDateTime(sr.Time))]);
    FindClose(sr);
  end
  else
    Result := 'not found';
end;

function OSVersionText: string;
begin
  Result := Format('Windows %d.%d build %d', [Win32MajorVersion, Win32MinorVersion, Win32BuildNumber]);
end;

function CpuCount: Integer;
begin
  Result := TThread.ProcessorCount;
end;

function BuildInfoText: string;
begin
  // exe timestamp, not {$I %DATE%}: that would be when this unit was last compiled
  Result := 'FPC ' + {$I %FPCVERSION%} + ' ' + {$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%} +
    ', exe ' + FormatDateTime('yyyy-mm-dd hh:nn', FileDateToDateTime(FileAge(ParamStr(0))));
end;

procedure ReadGLStrings(out Vendor, Renderer, Version: string);
begin
  Vendor := string(glGetString(GL_VENDOR));
  Renderer := string(glGetString(GL_RENDERER));
  Version := string(glGetString(GL_VERSION));
end;

end.
