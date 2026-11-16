// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.StackWalker;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.IOUtils;

type
  /// <summary>Internal line symbol mapping structure.</summary>
  /// <exclude/>
  TDFLineSymbol = record
    /// <summary>Source code line number.</summary>
    LineNumber: Integer;
    /// <summary>Offset of the line's code within the code segment.</summary>
    RVA: NativeUInt;
  end;

  /// <summary>Internal procedure symbol mapping structure.</summary>
  /// <exclude/>
  TDFProcSymbol = record
    /// <summary>Fully qualified procedure or method name.</summary>
    Name: string;
    /// <summary>Offset of the procedure's code within the code segment.</summary>
    RVA: NativeUInt;
  end;

  /// <summary>Container mapping line numbers to unit source files.</summary>
  /// <exclude/>
  TDFUnitLines = record
    /// <summary>Delphi source unit file name.</summary>
    UnitName: string;
    /// <summary>Array of line number symbols contained within the unit.</summary>
    Lines: TArray<TDFLineSymbol>;
  end;

  /// <summary>
  /// Thread-safe MAP file parser resolving runtime module memory addresses to Delphi source file locations.
  /// </summary>
  /// <exclude/>
  TDFMapFileReader = class
  private type
    TLineRef = record
      RVA: NativeUInt;
      LineNumber: Integer;
      UnitIndex: Integer;
    end;
  private
    FProcs: TList<TDFProcSymbol>;
    FUnitLines: TList<TDFUnitLines>;
    FLineIndex: TArray<TLineRef>;
    FIsLoaded: Boolean;
    FCodeSegmentRVA: NativeUInt;
    FCodeSegmentSize: NativeUInt;
    FLock: TCriticalSection;
    procedure ParseMapFile(const AMapFileName: string);
    procedure BuildLineIndex;
    procedure ReadCodeSegment;
    function ParseOffset(const AAddress: string; out AOffset: NativeUInt): Boolean;
  public
    /// <summary>
    /// Initializes map reader. Searches automatically for executable .map file if path is omitted.
    /// </summary>
    /// <param name="AMapFileName">Optional explicit file path to .map file.</param>
    constructor Create(const AMapFileName: string = '');
    destructor Destroy; override;

    /// <summary>
    /// Resolves an RVA memory address into unit name, procedure identifier, and line number.
    /// </summary>
    /// <param name="ARVA">Address relative to the base address of the executable.</param>
    /// <param name="AUnitName">Receives source unit name if found.</param>
    /// <param name="AProcName">Receives procedure or method name if found.</param>
    /// <param name="ALineNumber">Receives source line number if found, otherwise 0.</param>
    /// <returns>True if the address lies in the code segment and a procedure was found for it.</returns>
    function ResolveRVA(ARVA: NativeUInt; out AUnitName, AProcName: string; out ALineNumber: Integer): Boolean;
    /// <summary>Indicates whether MAP symbol file was loaded successfully.</summary>
    property IsLoaded: Boolean read FIsLoaded;
  end;

  /// <summary>
  /// Records call stacks and turns them into text with unit, method and line number.
  /// </summary>
  /// <remarks>
  /// Names and line numbers come from the MAP file next to the executable, with the same name
  /// and the extension .map (project options, Linker, Map file: Detailed). Without it, frames
  /// appear as module name plus offset, which can be resolved later with the MAP file of the
  /// same build. The MAP file is read on the first stack trace. Only Windows is supported;
  /// on other platforms stack traces are empty.
  /// </remarks>
  TDFStackWalker = class
  private
    class var FMapReader: TDFMapFileReader;
    class var FLock: TCriticalSection;
    class var FHooksInstalled: Boolean;
    class function GetMapReader: TDFMapFileReader;
    // Private, so that they stay out of the API documentation; the compiler calls them
    // regardless of visibility
    class constructor Create;
    class destructor Destroy;
  public
    /// <summary>
    /// Records the call stack of every exception where it is raised, so that
    /// <c>Exception.StackTrace</c> shows where the error occurred.
    /// </summary>
    /// <remarks>
    /// Does nothing if another tool (for example madExcept, EurekaLog or the JCL) already
    /// provides stack information for exceptions; its stack traces are used instead.
    /// Each raised exception then costs one stack capture and about 330 bytes of memory,
    /// also when it is handled. <c>TDFTraceHub</c> calls this automatically at runtime.
    /// In 32-bit programs, the stack trace of a hardware exception such as an access
    /// violation or a division by zero shows only the line where it occurred, not its
    /// callers.
    /// </remarks>
    class procedure InstallExceptionStackHooks; static;

    /// <summary>
    /// Returns the current call stack as text.
    /// </summary>
    /// <param name="ASkipFrames">Number of frames left out at the top; 0 starts inside
    /// GetStackTrace itself, 1 at the line that calls GetStackTrace.</param>
    /// <param name="AMaxFrames">Maximum number of frames, at most 64.</param>
    /// <returns>One line per frame. Frames that cannot be resolved, for example without a MAP
    /// file or outside the executable, appear as module name plus offset.</returns>
    class function GetStackTrace(ASkipFrames: Integer = 1; AMaxFrames: Integer = 32): string; static;
  end;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows;

const
  GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = $00000002;
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = $00000004;

function CaptureStackBackTrace(FramesToSkip, FramesToCapture: DWORD;
  BackTrace: PPointer; BackTraceHash: PDWORD): WORD; stdcall;
  external kernel32 name 'RtlCaptureStackBackTrace';

function GetModuleHandleExW(dwFlags: DWORD; lpModuleName: Pointer;
  out phModule: HMODULE): BOOL; stdcall;
  external kernel32 name 'GetModuleHandleExW';
{$ENDIF}

const
  // Delphi MAP files number the PE sections; segment 0001 is the code section (.text)
  CodeSegmentPrefix = '0001:';

{$IFDEF MSWINDOWS}
const
  MaxRaiseFrames = 40;
  // Exception code of a Delphi raise statement; hardware exceptions have other codes
  DelphiExceptionCode = $0EEDFADE;

type
  PRaiseStackInfo = ^TRaiseStackInfo;
  TRaiseStackInfo = record
    ExceptionAddress: Pointer;
    IsDelphiRaise: Boolean;
    Count: Integer;
    Frames: array[0..MaxRaiseFrames - 1] of Pointer;
  end;

function ModuleOf(AAddress: Pointer): HMODULE;
begin
  if not GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or
    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, AAddress, Result) then
    Result := 0;
end;

// AFirstIsExact: the first frame is the address of a faulting instruction, as with an
// access violation. All other frames are return addresses.
function FormatFrames(const AFrames: TArray<Pointer>; AFirstIsExact: Boolean): string;
var
  MainModule, FrameModule: HMODULE;
  ModuleName, UnitName, ProcName: string;
  LineNo, I: Integer;
  Reader: TDFMapFileReader;
  SB: TStringBuilder;
  Frame: Pointer;
  Address, LookupAddress: NativeUInt;
begin
  Result := '';
  if Length(AFrames) = 0 then Exit;

  MainModule := GetModuleHandle(nil);
  Reader := TDFStackWalker.GetMapReader;
  SB := TStringBuilder.Create;
  try
    for I := 0 to High(AFrames) do
    begin
      Frame := AFrames[I];
      // The frame chain ends at code without a stack frame, such as the main block of a
      // program; RtlCaptureStackBackTrace then returns nil for the rest
      if Frame = nil then
        Break;
      Address := NativeUInt(Frame);
      // A return address points behind the call, which may already belong to the next
      // source line. One byte back lies inside the call instruction.
      if (I = 0) and AFirstIsExact then
        LookupAddress := Address
      else
        LookupAddress := Address - 1;
      FrameModule := ModuleOf(Frame);

      if FrameModule = 0 then
        SB.AppendFormat('  at $%p', [Frame]).AppendLine
      else if (FrameModule = MainModule) and
        Reader.ResolveRVA(LookupAddress - NativeUInt(MainModule), UnitName, ProcName, LineNo) then
      begin
        SB.AppendFormat('  at %s', [ProcName]);
        if not UnitName.IsEmpty then
          SB.AppendFormat(' in %s', [UnitName]);
        if LineNo > 0 then
          SB.AppendFormat(':line %d', [LineNo]);
        SB.AppendLine;
      end
      else
      begin
        // Module plus offset can still be resolved later with the MAP file of the build
        ModuleName := ExtractFileName(GetModuleName(FrameModule));
        SB.AppendFormat('  at %s+$%x', [ModuleName, Address - NativeUInt(FrameModule)]).AppendLine;
      end;
    end;
    Result := SB.ToString.TrimRight;
  finally
    SB.Free;
  end;
end;

// Called by the RTL for every raised exception, including handled ones. Only records
// addresses: resolving names here would slow down every exception.
// System.PExceptionRecord, not the one from Winapi.Windows: the signature must match
// Exception.GetExceptionStackInfoProc.
function GetRaiseStackInfo(P: System.PExceptionRecord): Pointer;
var
  Info: PRaiseStackInfo;
begin
  GetMem(Info, SizeOf(TRaiseStackInfo));
  if Assigned(P) then
  begin
    Info.ExceptionAddress := P.ExceptionAddress;
    Info.IsDelphiRaise := P.ExceptionCode = DelphiExceptionCode;
  end
  else
  begin
    Info.ExceptionAddress := nil;
    Info.IsDelphiRaise := True;
  end;
  // Skip this function and Exception.RaisingException, the only caller of
  // GetExceptionStackInfoProc in the RTL
  Info.Count := CaptureStackBackTrace(2, MaxRaiseFrames, @Info.Frames[0], nil);
  Result := Info;
end;

function GetRaiseStackString(AInfo: Pointer): string;
var
  Info: PRaiseStackInfo;
  Frames: TArray<Pointer>;
  NtDll: HMODULE;
  I, Start: Integer;
begin
  Result := '';
  Info := PRaiseStackInfo(AInfo);
  if not Assigned(Info) then Exit;

  // The captured stack may start inside the RTL raise code and, for hardware exceptions
  // such as access violations, inside the Windows exception dispatcher. The frame at the
  // exception address is where the code that raised the exception begins.
  Start := -1;
  for I := 0 to Info.Count - 1 do
    if Info.Frames[I] = Info.ExceptionAddress then
    begin
      Start := I;
      Break;
    end;

  Frames := nil;
  if Start < 0 then
  begin
    // The exception address is often not among the captured frames: the faulting
    // instruction of a hardware exception is no call, and System._RaiseExcept has no stack
    // frame of its own. For a hardware exception the callers follow the last frame of the
    // Windows dispatcher.
    NtDll := GetModuleHandle('ntdll.dll');
    for I := 0 to Info.Count - 1 do
      if ModuleOf(Info.Frames[I]) = NtDll then
        Start := I + 1;
    if Assigned(Info.ExceptionAddress) then
      Frames := [Info.ExceptionAddress];

    if Start < 0 then
    begin
      if Info.IsDelphiRaise then
        // After a raise statement the captured frames are the callers
        Start := 0
      else
        // A hardware exception without dispatcher frames: in 32-bit programs the frame
        // chain seen from the exception handler ends in the RTL handler code and never
        // reaches the callers. Those frames would only mislead, so only the faulting line
        // is shown.
        Start := Info.Count;
    end;
  end;

  for I := Start to Info.Count - 1 do
    Frames := Frames + [Info.Frames[I]];

  // After a raise statement the exception address is a return address; after a hardware
  // exception it is the faulting instruction itself
  Result := FormatFrames(Frames, not Info.IsDelphiRaise);
end;

procedure CleanUpRaiseStackInfo(AInfo: Pointer);
begin
  FreeMem(AInfo);
end;
{$ENDIF}

{ TDFMapFileReader }

constructor TDFMapFileReader.Create(const AMapFileName: string);
var
  TargetMap: string;
begin
  inherited Create;
  FProcs := TList<TDFProcSymbol>.Create;
  FUnitLines := TList<TDFUnitLines>.Create;
  FLock := TCriticalSection.Create;
  FIsLoaded := False;
  ReadCodeSegment;

  if AMapFileName <> '' then
    TargetMap := AMapFileName
  else
    TargetMap := ChangeFileExt(ParamStr(0), '.map');

  if TFile.Exists(TargetMap) then
    ParseMapFile(TargetMap);
end;

destructor TDFMapFileReader.Destroy;
begin
  FreeAndNil(FProcs);
  FreeAndNil(FUnitLines);
  FreeAndNil(FLock);
  inherited Destroy;
end;

procedure TDFMapFileReader.ReadCodeSegment;
{$IFDEF MSWINDOWS}
var
  Base: NativeUInt;
  NtHeaders: PImageNtHeaders;
  FirstSection: PImageSectionHeader;
{$ENDIF}
begin
  // Fallback: the usual position of the code section in Delphi executables
  FCodeSegmentRVA := $1000;
  FCodeSegmentSize := High(NativeUInt) - $1000;
{$IFDEF MSWINDOWS}
  // The MAP file belongs to the executable, so the executable is the reference module,
  // also when this code runs inside a runtime package.
  Base := NativeUInt(GetModuleHandle(nil));
  NtHeaders := PImageNtHeaders(Base + NativeUInt(PImageDosHeader(Base)._lfanew));
  if NtHeaders.FileHeader.NumberOfSections = 0 then Exit;
  FirstSection := PImageSectionHeader(NativeUInt(@NtHeaders.OptionalHeader) +
    NtHeaders.FileHeader.SizeOfOptionalHeader);
  FCodeSegmentRVA := FirstSection.VirtualAddress;
  FCodeSegmentSize := FirstSection.Misc.VirtualSize;
{$ENDIF}
end;

function TDFMapFileReader.ParseOffset(const AAddress: string; out AOffset: NativeUInt): Boolean;
var
  Value: Int64;
begin
  // Format "0001:0000ABCD"; only the code segment is relevant for stack frames
  Result := AAddress.StartsWith(CodeSegmentPrefix) and
    TryStrToInt64('$' + AAddress.Substring(Length(CodeSegmentPrefix)), Value) and (Value >= 0);
  if Result then
    AOffset := NativeUInt(Value)
  else
    AOffset := 0;
end;

procedure TDFMapFileReader.ParseMapFile(const AMapFileName: string);
var
  Lines: TArray<string>;
  Line, Trimmed, CurrentUnit: string;
  I, ParenIdx: Integer;
  State: (stNone, stPublics, stLines, stSkipLines);
  Proc: TDFProcSymbol;
  UnitLineObj: TDFUnitLines;
  TempLines: TList<TDFLineSymbol>;
  Parts: TArray<string>;
  Offset: NativeUInt;
  LineNo: Integer;
  LineSym: TDFLineSymbol;

  procedure StoreCurrentUnit;
  begin
    if (CurrentUnit <> '') and (TempLines.Count > 0) then
    begin
      UnitLineObj.UnitName := CurrentUnit;
      UnitLineObj.Lines := TempLines.ToArray;
      FUnitLines.Add(UnitLineObj);
    end;
    TempLines.Clear;
  end;

begin
  try
    Lines := TFile.ReadAllLines(AMapFileName, TEncoding.ANSI);
  except
    Exit;
  end;

  State := stNone;
  CurrentUnit := '';
  TempLines := TList<TDFLineSymbol>.Create;
  try
    for Line in Lines do
    begin
      Trimmed := Line.Trim;
      if Trimmed.IsEmpty then Continue;

      if Trimmed.StartsWith('Address') and Trimmed.Contains('Publics by Value') then
      begin
        StoreCurrentUnit;
        State := stPublics;
        Continue;
      end;

      // Example: "Line numbers for System(System.pas) segment .text"
      if Trimmed.StartsWith('Line numbers for') then
      begin
        StoreCurrentUnit;
        ParenIdx := Trimmed.IndexOf('(');
        if ParenIdx > 17 then
          CurrentUnit := Trimmed.Substring(17, ParenIdx - 17).Trim
        else
          CurrentUnit := '';
        // Lines in other segments (e.g. .itext) use offsets relative to that segment
        if Trimmed.EndsWith('segment .text') then
          State := stLines
        else
          State := stSkipLines;
        Continue;
      end;

      if Trimmed.StartsWith('Bound resource files') or Trimmed.StartsWith('Detailed map of segments') then
      begin
        StoreCurrentUnit;
        State := stNone;
        Continue;
      end;

      case State of
        stPublics:
          begin
            // Example: "0001:0000ABCD       System.TObject.Create"
            Parts := Trimmed.Split([' '], TStringSplitOptions.ExcludeEmpty);
            if (Length(Parts) >= 2) and ParseOffset(Parts[0], Offset) then
            begin
              Proc.RVA := Offset;
              Proc.Name := string.Join(' ', Parts, 1, Length(Parts) - 1);
              FProcs.Add(Proc);
            end;
          end;

        stLines:
          begin
            // Example: "  123 0001:0000ABCD   124 0001:0000ABD2"
            Parts := Trimmed.Split([' '], TStringSplitOptions.ExcludeEmpty);
            I := 0;
            while I < Length(Parts) - 1 do
            begin
              LineNo := StrToIntDef(Parts[I], 0);
              if (LineNo > 0) and ParseOffset(Parts[I + 1], Offset) then
              begin
                LineSym.LineNumber := LineNo;
                LineSym.RVA := Offset;
                TempLines.Add(LineSym);
              end;
              Inc(I, 2);
            end;
          end;
      end;
    end;

    StoreCurrentUnit;
  finally
    TempLines.Free;
  end;

  FProcs.Sort(TComparer<TDFProcSymbol>.Construct(
    function(const L, R: TDFProcSymbol): Integer
    begin
      if L.RVA < R.RVA then Result := -1
      else if L.RVA > R.RVA then Result := 1
      else Result := 0;
    end));

  BuildLineIndex;
  FIsLoaded := (FProcs.Count > 0);
end;

procedure TDFMapFileReader.BuildLineIndex;
var
  UnitIdx, Count: Integer;
  Sym: TDFLineSymbol;
begin
  // One sorted list over all units, so that a lookup is a binary search
  Count := 0;
  for UnitIdx := 0 to FUnitLines.Count - 1 do
    Inc(Count, Length(FUnitLines[UnitIdx].Lines));

  SetLength(FLineIndex, Count);
  Count := 0;
  for UnitIdx := 0 to FUnitLines.Count - 1 do
    for Sym in FUnitLines[UnitIdx].Lines do
    begin
      FLineIndex[Count].RVA := Sym.RVA;
      FLineIndex[Count].LineNumber := Sym.LineNumber;
      FLineIndex[Count].UnitIndex := UnitIdx;
      Inc(Count);
    end;

  TArray.Sort<TLineRef>(FLineIndex, TComparer<TLineRef>.Construct(
    function(const L, R: TLineRef): Integer
    begin
      if L.RVA < R.RVA then Result := -1
      else if L.RVA > R.RVA then Result := 1
      else Result := 0;
    end));
end;

function TDFMapFileReader.ResolveRVA(ARVA: NativeUInt; out AUnitName, AProcName: string;
  out ALineNumber: Integer): Boolean;
var
  Offset, ProcStart: NativeUInt;
  LowIdx, HighIdx, MidIdx, BestIdx: Integer;
begin
  AUnitName := '';
  AProcName := '';
  ALineNumber := 0;
  Result := False;

  if not FIsLoaded then Exit;
  if (ARVA < FCodeSegmentRVA) or (ARVA - FCodeSegmentRVA >= FCodeSegmentSize) then Exit;

  // MAP offsets are relative to the start of the code segment, not to the module base
  Offset := ARVA - FCodeSegmentRVA;

  FLock.Enter;
  try
    // Procedure: last entry at or before the offset
    LowIdx := 0;
    HighIdx := FProcs.Count - 1;
    BestIdx := -1;
    while LowIdx <= HighIdx do
    begin
      MidIdx := (LowIdx + HighIdx) div 2;
      if FProcs[MidIdx].RVA <= Offset then
      begin
        BestIdx := MidIdx;
        LowIdx := MidIdx + 1;
      end
      else
        HighIdx := MidIdx - 1;
    end;

    if BestIdx < 0 then Exit;
    AProcName := FProcs[BestIdx].Name;
    ProcStart := FProcs[BestIdx].RVA;
    Result := True;

    // Line: last entry at or before the offset
    LowIdx := 0;
    HighIdx := High(FLineIndex);
    BestIdx := -1;
    while LowIdx <= HighIdx do
    begin
      MidIdx := (LowIdx + HighIdx) div 2;
      if FLineIndex[MidIdx].RVA <= Offset then
      begin
        BestIdx := MidIdx;
        LowIdx := MidIdx + 1;
      end
      else
        HighIdx := MidIdx - 1;
    end;

    // A line before the start of the procedure belongs to a different procedure
    if (BestIdx >= 0) and (FLineIndex[BestIdx].RVA >= ProcStart) then
    begin
      ALineNumber := FLineIndex[BestIdx].LineNumber;
      AUnitName := FUnitLines[FLineIndex[BestIdx].UnitIndex].UnitName;
    end;
  finally
    FLock.Leave;
  end;
end;

{ TDFStackWalker }

class constructor TDFStackWalker.Create;
begin
  FLock := TCriticalSection.Create;
  FMapReader := nil;
end;

class destructor TDFStackWalker.Destroy;
begin
{$IFDEF MSWINDOWS}
  // Resolving needs the MAP reader freed below. Recording and cleanup do not, and cleanup
  // stays installed so that exceptions freed later do not leave their stack info behind.
  if FHooksInstalled then
  begin
    Exception.GetExceptionStackInfoProc := nil;
    Exception.GetStackInfoStringProc := nil;
    FHooksInstalled := False;
  end;
{$ENDIF}
  FreeAndNil(FMapReader);
  FreeAndNil(FLock);
end;

class function TDFStackWalker.GetMapReader: TDFMapFileReader;
begin
  if not Assigned(FMapReader) then
  begin
    FLock.Enter;
    try
      if not Assigned(FMapReader) then
        FMapReader := TDFMapFileReader.Create;
    finally
      FLock.Leave;
    end;
  end;
  Result := FMapReader;
end;

class function TDFStackWalker.GetStackTrace(ASkipFrames, AMaxFrames: Integer): string;
{$IFDEF MSWINDOWS}
var
  StackPointers: array[0..63] of Pointer;
  CapturedCount: WORD;
  Frames: TArray<Pointer>;
  I: Integer;
{$ENDIF}
begin
  Result := '';
{$IFDEF MSWINDOWS}
  if AMaxFrames > 64 then AMaxFrames := 64;

  CapturedCount := CaptureStackBackTrace(ASkipFrames, AMaxFrames, @StackPointers[0], nil);
  SetLength(Frames, CapturedCount);
  for I := 0 to CapturedCount - 1 do
    Frames[I] := StackPointers[I];
  Result := FormatFrames(Frames, False);
{$ENDIF}
end;

class procedure TDFStackWalker.InstallExceptionStackHooks;
begin
{$IFDEF MSWINDOWS}
  FLock.Enter;
  try
    if FHooksInstalled then Exit;
    // Leave another stack trace provider in place: Exception.StackTrace then comes from it
    if Assigned(Exception.GetExceptionStackInfoProc) or Assigned(Exception.GetStackInfoStringProc) or
      Assigned(Exception.CleanUpStackInfoProc) then Exit;

    Exception.GetExceptionStackInfoProc := @GetRaiseStackInfo;
    Exception.GetStackInfoStringProc := @GetRaiseStackString;
    Exception.CleanUpStackInfoProc := @CleanUpRaiseStackInfo;
    FHooksInstalled := True;
  finally
    FLock.Leave;
  end;
{$ENDIF}
end;

end.
