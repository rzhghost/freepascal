{
    This file is part of the Free Component Library (FCL)
    Copyright (c) 2016 by Graeme Geldenhuys

    This unit creates a new TTF subset font file, reducing the file
    size in the process. This is primarily so the new font file can
    be embedded in PDF documents.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
unit fpTTFSubsetter;

{$mode objfpc}{$H+}

{ $R+}

// enable this define for more verbose output
{.$define gdebug}

interface

uses
  Classes,
  SysUtils,
  fpparsettf,
  FPFontTextMapping;

type
  ETTFSubsetter = class(Exception);

  TArrayUInt32 = array of UInt32;


  TFontSubsetter = class(TObject)
  private
    FPrefix: string;
    FHasAddedCompoundReferences: boolean;  // one glyph made up of multiple glyphs
    FKeepTables: TStrings;
    FFontInfo: TTFFileInfo;
    FGlyphIDList: TTextMappingList;
    FStream: TFileStream; // original TTF file
    FGlyphLocations: array of UInt32;
    function    Int32HighestOneBit(const AValue: integer): integer;
    function    Int32Log2(const AValue: integer): integer;
    function    ToUInt32(const AHigh, ALow: UInt32): UInt32;
    function    ToUInt32(const ABytes: AnsiString): UInt32;
    function    GetRawTable(const ATableName: AnsiString): TMemoryStream;
    function    WriteFileHeader(AOutStream: TStream; const nTables: integer): uint32;
    function    WriteTableHeader(AOutStream: TStream; const ATag: AnsiString; const AOffset: UInt32; const AData: TStream): uint32;
    procedure   WriteTableBodies(AOutStream: TStream; const ATables: TStringList);
    // AGlyphID is the original GlyphID in the original TTF file
    function    GetCharIDfromGlyphID(const AGlyphID: uint32): uint32;
    { Copy glyph data as-is for a specific glyphID. }
    function    GetRawGlyphData(const AGlyphID: UInt16): TMemoryStream;
    procedure   LoadLocations;
    // Stream writing functions.
    procedure   WriteInt16(AStream: TStream; const AValue: Int16); inline;
    procedure   WriteUInt32(AStream: TStream; const AValue: UInt32); inline;
    procedure   WriteUInt16(AStream: TStream; const AValue: UInt16); inline;
    function    ReadInt16(AStream: TStream): Int16; inline;
    function    ReadUInt32(AStream: TStream): UInt32; inline;
    function    ReadUInt16(AStream: TStream): UInt16; inline;

    procedure   AddCompoundReferences;
    function    buildHeadTable: TStream;
    function    buildHheaTable: TStream;
    function    buildMaxpTable: TStream;
    function    buildFpgmTable: TStream;
    function    buildPrepTable: TStream;
    function    buildCvtTable: TStream;
    function    buildGlyfTable(var newOffsets: TArrayUInt32): TStream;
    function    buildLocaTable(var newOffsets: TArrayUInt32): TStream;
    function    buildCmapTable: TStream;
    function    buildHmtxTable: TStream;
  public
    constructor Create(const AFont: TTFFileInfo; const AGlyphIDList: TTextMappingList);
    constructor Create(const AFont: TTFFileInfo);
    destructor  Destroy; override;
    procedure   SaveToFile(const AFileName: String);
    procedure   SaveToStream(const AStream: TStream);
    // Add the given Unicode codepoint to the subset.
    procedure   Add(const ACodePoint: uint32);
    // The prefix to add to the font's PostScript name.
    property    Prefix: string read FPrefix write FPrefix;
  end;



implementation

uses
  math;

resourcestring
  rsErrFontInfoNotAssigned = 'FontInfo was not assigned';
  rsErrFailedToReadFromStream = 'Failed to read from file stream';
  rsErrCantFindFontFile = 'Can''t find the actual TTF font file.';
  rsErrGlyphLocationsNotLoaded = 'Glyph Location data has not been loaded yet.';

const
  PAD_BUF: array[ 1..3 ] of Byte = ( $0, $0, $0 );


{ TFontSubsetter }

{ The method simply returns the int value with a single one-bit, in the position
  of the highest-order one-bit in the specified value, or zero if the specified
  value is itself equal to zero. }
function TFontSubsetter.Int32HighestOneBit(const AValue: integer): integer;
var
  i: integer;
begin
  i := AValue;
  i := i or (i shr 1);
  i := i or (i shr 2);
  i := i or (i shr 4);
  i := i or (i shr 8);
  i := i or (i shr 16);
//  i := i or (i shr 32);
  Result := i - (i shr 1);
end;

function TFontSubsetter.Int32Log2(const AValue: integer): integer;
begin
  if AValue <= 0 then
    raise Exception.Create('Illegal argument');
//  Result :=  31 - Integer.numberOfLeadingZeros(n);

  Result := Floor(Log10(AValue) / Log10(2));
end;

function TFontSubsetter.ToUInt32(const AHigh, ALow: UInt32): UInt32;
begin
  result := ((AHigh and $FFFF) shl 16) or (ALow and $FFFF);
end;

function TFontSubsetter.ToUInt32(const ABytes: AnsiString): UInt32;
var
  b: array of Byte absolute ABytes;
begin
  Result := (b[0] and $FF) shl 24
           or (b[1] and $FF) shl 16
           or (b[2] and $FF) shl 8
           or (b[3] and $FF);
end;

function TFontSubsetter.GetRawTable(const ATableName: AnsiString): TMemoryStream;
var
  lEntry: TTableDirectoryEntry;
begin
  Result := nil;
  FillMem(@lEntry, SizeOf(TTableDirectoryEntry), 0);
  if not FFontInfo.GetTableDirEntry(ATableName, lEntry) then
    Exit;

  Result := TMemoryStream.Create;
  FStream.Seek(lEntry.offset, soFromBeginning);
  if Result.CopyFrom(FStream, lEntry.Length) <> lEntry.Length then
    raise ETTF.Create('GetRawTable: ' + rsErrFailedToReadFromStream);
end;

{ AOutStream: the data output stream.
  nTables: the number of font tables.
  result: the file offset of the first TTF table to write. }
function TFontSubsetter.WriteFileHeader(AOutStream: TStream; const nTables: integer): uint32;
var
  mask: integer;
  searchRange: integer;
  entrySelector: integer;
  rangeShift: integer;
begin
  WriteUInt32(AOutStream, $00010000);
  WriteUInt16(AOutStream, nTables);

  mask := Int32HighestOneBit(nTables);
  searchRange := mask * 16;
  WriteUInt16(AOutStream, searchRange);

  entrySelector := Int32Log2(mask);
  WriteUInt16(AOutStream, entrySelector);

  rangeShift := 16 * nTables - searchRange;
  WriteUInt16(AOutStream, rangeShift);

  result := $00010000 + ToUInt32(nTables, searchRange) + ToUInt32(entrySelector, rangeShift);
end;

function TFontSubsetter.WriteTableHeader(AOutStream: TStream; const ATag: AnsiString; const AOffset: UInt32;
  const AData: TStream): uint32;
var
  checksum: UInt32;
  n: integer;
  lByte: Byte;
begin
  AData.Position := 0;
  checksum := 0;

  for n := 0 to AData.Size-1 do
  begin
    lByte := AData.ReadByte;
    checksum := checksum + (((lByte and $FF) shl 24) - n mod 4 * 8);
  end;
  checksum := checksum and $FFFFFFFF;

  AOutStream.WriteBuffer(Pointer(ATag)^, 4); // Tag is always 4 bytes - written as-is, no NtoBE() required
  WriteUInt32(AOutStream, checksum);
  WriteUInt32(AOutStream, AOffset);
  WriteUInt32(AOutStream, AData.Size);

  {$ifdef gdebug}
  writeln(Format('tag: "%s"  CRC: %8.8x  offset: %8.8x (%2:7d bytes)  size: %8.8x (%3:7d bytes)', [ATag, checksum, AOffset, AData.Size]));
  {$endif}

  // account for the checksum twice, once for the header field, once for the content itself
  Result := ToUInt32(ATag) + checksum + checksum + AOffset + AData.Size;
end;

procedure TFontSubsetter.WriteTableBodies(AOutStream: TStream; const ATables: TStringList);
var
  i: integer;
  n: uint64;
  lData: TStream;
begin
  for i := 0 to ATables.Count-1 do
  begin
    lData := TStream(ATables.Objects[i]);
    if lData <> nil then
    begin
      lData.Position := 0;
      n := lData.Size;
      AOutStream.CopyFrom(lData, lData.Size);
    end;
    if (n mod 4) <> 0 then
    begin
      {$ifdef gdebug}
      writeln('Padding applied at the end of ', ATables[i], ': ', 4 - (n mod 4), ' byte(s)');
      {$endif}
      AOutStream.WriteBuffer(PAD_BUF, 4 - (n mod 4));
    end;
  end;
end;

function TFontSubsetter.GetCharIDfromGlyphID(const AGlyphID: uint32): uint32;
var
  i: integer;
begin
  Result := 0;
  for i := 0 to Length(FFontInfo.Chars)-1 do
    if FFontInfo.Chars[i] = AGlyphID then
    begin
      Result := i;
      Exit;
    end;
end;

function TFontSubsetter.GetRawGlyphData(const AGlyphID: UInt16): TMemoryStream;
var
  lGlyf: TTableDirectoryEntry;
  lSize: UInt16;
begin
  Result := nil;
  if Length(FGlyphLocations) < 2 then
    raise ETTF.Create(rsErrGlyphLocationsNotLoaded);
  FillMem(@lGlyf, SizeOf(TTableDirectoryEntry), 0);
  FFontInfo.GetTableDirEntry(TTFTableNames[ttglyf], lGlyf);

  lSize := FGlyphLocations[AGlyphID+1] - FGlyphLocations[AGlyphID];
  Result := TMemoryStream.Create;
  if lSize > 0 then
  begin
    FStream.Seek(lGlyf.offset + FGlyphLocations[AGlyphID], soFromBeginning);
    if Result.CopyFrom(FStream, lSize) <> lSize then
      raise ETTF.Create('GetRawGlyphData: ' + rsErrFailedToReadFromStream)
    else
      Result.Position := 0;
  end;
end;

procedure TFontSubsetter.LoadLocations;
var
  lLocaEntry: TTableDirectoryEntry;
  lGlyf: TTableDirectoryEntry;
  ms: TMemoryStream;
  numLocations: integer;
  n: integer;
begin
  FillMem(@lGlyf, SizeOf(TTableDirectoryEntry), 0);
  FillMem(@lLocaEntry, SizeOf(TTableDirectoryEntry), 0);

  FFontInfo.GetTableDirEntry(TTFTableNames[ttglyf], lGlyf);
  if FFontInfo.GetTableDirEntry(TTFTableNames[ttloca], lLocaEntry) then
  begin
    ms := TMemoryStream.Create;
    try
      FStream.Seek(lLocaEntry.offset, soFromBeginning);
      if ms.CopyFrom(FStream, lLocaEntry.Length) <> lLocaEntry.Length then
        raise ETTF.Create('LoadLocations: ' + rsErrFailedToReadFromStream)
      else
        ms.Position := 0;

      if FFontInfo.Head.IndexToLocFormat = 0 then
      begin
        // Short offsets
        numLocations := lLocaEntry.Length shr 1;
        {$IFDEF gDEBUG}
        Writeln('Number of Glyph locations ( 16 bits offsets ): ', numLocations );
        {$ENDIF}
        SetLength(FGlyphLocations, numLocations);
        for n := 0 to numLocations-1 do
          FGlyphLocations[n] := BEtoN(ms.ReadWord) * 2;
      end
      else
      begin
        // Long offsets
        numLocations := lLocaEntry.Length shr 2;
        {$IFDEF gDEBUG}
        Writeln('Number of Glyph locations ( 32 bits offsets ): ', numLocations );
        {$ENDIF}
        SetLength(FGlyphLocations, numLocations);
        for n := 0 to numLocations-1 do
          FGlyphLocations[n] := BEtoN(ms.ReadDWord);
      end;
    finally
      ms.Free;
    end;
  end
  else
  begin
    {$ifdef gDEBUG}
    Writeln('WARNING: ''loca'' table is not found.');
    {$endif}
  end;
end;

procedure TFontSubsetter.WriteInt16(AStream: TStream; const AValue: Int16);
begin
  AStream.WriteBuffer(NtoBE(AValue), 2);
end;

procedure TFontSubsetter.WriteUInt32(AStream: TStream; const AValue: UInt32);
begin
  AStream.WriteDWord(NtoBE(AValue));
end;

procedure TFontSubsetter.WriteUInt16(AStream: TStream; const AValue: UInt16);
begin
  AStream.WriteWord(NtoBE(AValue));
end;

function TFontSubsetter.ReadInt16(AStream: TStream): Int16;
begin
  Result:=Int16(ReadUInt16(AStream));
end;

function TFontSubsetter.ReadUInt32(AStream: TStream): UInt32;
begin
  Result:=0;
  AStream.ReadBuffer(Result,SizeOf(Result));
  Result:=BEtoN(Result);
end;

function TFontSubsetter.ReadUInt16(AStream: TStream): UInt16;
begin
  Result:=0;
  AStream.ReadBuffer(Result,SizeOf(Result));
  Result:=BEtoN(Result);
end;

procedure TFontSubsetter.AddCompoundReferences;
var
  GlyphIDsToAdd: TStringList;
  n: integer;
  gs: TMemoryStream;
  buf: TGlyphHeader;
  i: integer;
  flags: uint16;
  glyphIndex: uint16;
  cid: uint16;
  hasNested: boolean;
begin
  if FhasAddedCompoundReferences then
    Exit;
  FhasAddedCompoundReferences := True;

  LoadLocations;

  repeat
    GlyphIDsToAdd := TStringList.Create;
    GlyphIDsToAdd.Duplicates := dupIgnore;
    GlyphIDsToAdd.Sorted := True;

    for n := 0 to FGlyphIDList.Count-1 do
    begin
      if not Assigned(FGlyphIDList[n].GlyphData) then
        FGlyphIDList[n].GlyphData := GetRawGlyphData(FGlyphIDList[n].GlyphID);
      gs := TMemoryStream(FGlyphIDList[n].GlyphData);
      gs.Position := 0;

      if gs.Size > 0 then
      begin
        FillMem(@buf, SizeOf(TGlyphHeader), 0);
        gs.ReadBuffer(buf, SizeOf(Buf));

        if buf.numberOfContours = -1 then
        begin
          FGlyphIDList[n].IsCompoundGlyph := True;
          {$IFDEF gDEBUG}
          writeln('char: ', IntToHex(FGlyphIDList[n].CharID, 4));
          writeln('   glyph data size: ', gs.Size);
          writeln('   numberOfContours: ', buf.numberOfContours);
          {$ENDIF}
          repeat
            flags := ReadUInt16(gs);
            glyphIndex := ReadUInt16(gs);
            // find compound glyph ID's and add them to the GlyphIDsToAdd list
            if not FGlyphIDList.Contains(glyphIndex) then
            begin
              {$IFDEF gDEBUG}
              writeln(Format('      glyphIndex: %.4x (%0:d) ', [glyphIndex]));
              {$ENDIF}
              GlyphIDsToAdd.Add(IntToStr(glyphIndex));
            end;
            // ARG_1_AND_2_ARE_WORDS
            if (flags and (1 shl 0)) <> 0 then
              ReadUInt32(gs)
            else
              ReadUInt16(gs);
            // WE_HAVE_A_TWO_BY_TWO
            if (flags and (1 shl 7)) <> 0 then
            begin
              ReadUInt32(gs);
              ReadUInt32(gs);
            end
            // WE_HAVE_AN_X_AND_Y_SCALE
            else if (flags and (1 shl 6)) <> 0 then
            begin
              ReadUInt32(gs);
            end
            // WE_HAVE_A_SCALE
            else if (flags and (1 shl 3)) <> 0 then
            begin
              ReadUInt16(gs);
            end;

          until (flags and (1 shl 5)) = 0;   // MORE_COMPONENTS
        end;  { if buf.numberOfContours = -1 }
      end;  { if gs.Size > 0 }
    end; { for n ... FGlyphIDList.Count-1 }

    if GlyphIDsToAdd.Count > 0 then
    begin
      for i := 0 to GlyphIDsToAdd.Count-1 do
      begin
        glyphIndex := StrToInt(GlyphIDsToAdd[i]);
        cid := GetCharIDfromGlyphID(glyphIndex); // lookup original charID
        FGlyphIDList.Add(cid, glyphIndex);
      end;
    end;
    hasNested := GlyphIDsToAdd.Count > 0;
    FreeAndNil(GlyphIDsToAdd);
  until (hasNested = false);
end;

function TFontSubsetter.buildHeadTable: TStream;
var
  t: THead;
  rec: THead;
  i: Integer;
begin
  Result := TMemoryStream.Create;

  t := FFontInfo.Head;
  FillMem(@rec, SizeOf(THead), 0);
  rec.FileVersion.Version := NtoBE(t.FileVersion.Version);
  rec.FontRevision.Version := NtoBE(t.FontRevision.Version);
  rec.CheckSumAdjustment := 0;
  rec.MagicNumber := NtoBE(t.MagicNumber);
  rec.Flags := NtoBE(t.Flags);
  rec.UnitsPerEm := NtoBE(t.UnitsPerEm);
  rec.Created := NtoBE(t.Created);
  rec.Modified := NtoBE(t.Modified);
  For i := 0 to 3 do
    rec.BBox[i] := NtoBE(t.BBox[i]);
  rec.MacStyle := NtoBE(t.MacStyle);
  rec.LowestRecPPEM := NtoBE(t.LowestRecPPEM);
  rec.FontDirectionHint := NtoBE(t.FontDirectionHint);
  // force long format of 'loca' table. ie: 'loca' table offsets are in 4-Bytes each, not Words.
  rec.IndexToLocFormat := NtoBE(Int16(1)); //NtoBE(t.IndexToLocFormat);
  rec.glyphDataFormat := NtoBE(t.glyphDataFormat);

  Result.WriteBuffer(rec, SizeOf(THead));
end;

function TFontSubsetter.buildHheaTable: TStream;
var
  t: THHead;
  rec: THHead;
  hmetrics: UInt16;
begin
  Result := TMemoryStream.Create;

  t := FFontInfo.HHead;
  FillMem(@rec, SizeOf(THHead), 0);
  rec.TableVersion.Version := NtoBE(t.TableVersion.Version);
  rec.Ascender := NtoBE(t.Ascender);
  rec.Descender := NtoBE(t.Descender);
  rec.LineGap := NtoBE(t.LineGap);
  rec.AdvanceWidthMax := NtoBE(t.AdvanceWidthMax);
  rec.MinLeftSideBearing := NtoBE(t.MinLeftSideBearing);
  rec.MinRightSideBearing := NtoBE(t.MinRightSideBearing);
  rec.XMaxExtent := NtoBE(t.XMaxExtent);
  rec.CaretSlopeRise := NtoBE(t.CaretSlopeRise);
  rec.CaretSlopeRun := NtoBE(t.CaretSlopeRun);
  rec.caretOffset := NtoBE(t.caretOffset);
  rec.metricDataFormat := NtoBE(t.metricDataFormat);
//  rec.numberOfHMetrics := NtoBE(t.numberOfHMetrics);

  hmetrics := FGlyphIDList.Count;
  if (FGlyphIDList.Items[FGlyphIDList.Count-1].GlyphID >= t.numberOfHMetrics) and (not FGlyphIDList.Contains(t.numberOfHMetrics-1)) then
    inc(hmetrics);
  rec.numberOfHMetrics := NtoBE(hmetrics);

  Result.WriteBuffer(rec, SizeOf(THHead));
end;

function TFontSubsetter.buildMaxpTable: TStream;
var
  t: TMaxP;
  rec: TMaxP;
  lCount: word;
begin
  Result := TMemoryStream.Create;

  t := FFontInfo.MaxP;
  FillMem(@rec, SizeOf(TMaxP), 0);
  rec.VersionNumber.Version := NtoBE(t.VersionNumber.Version);

  lCount := FGlyphIDList.Count;
  rec.numGlyphs := NtoBE(lCount);

  rec.maxPoints := NtoBE(t.maxPoints);
  rec.maxContours := NtoBE(t.maxContours);
  rec.maxCompositePoints := NtoBE(t.maxCompositePoints);
  rec.maxCompositeContours := NtoBE(t.maxCompositeContours);
  rec.maxZones := NtoBE(t.maxZones);
  rec.maxTwilightPoints := NtoBE(t.maxTwilightPoints);
  rec.maxStorage := NtoBE(t.maxStorage);
  rec.maxFunctionDefs := NtoBE(t.maxFunctionDefs);
  rec.maxInstructionDefs := NtoBE(t.maxInstructionDefs);
  rec.maxStackElements := NtoBE(t.maxStackElements);
  rec.maxSizeOfInstructions := NtoBE(t.maxSizeOfInstructions);
  rec.maxComponentElements := NtoBE(t.maxComponentElements);
  rec.maxComponentDepth := NtoBE(t.maxComponentDepth);

  Result.WriteBuffer(rec, SizeOf(TMaxP));
end;

function TFontSubsetter.buildFpgmTable: TStream;
begin
  Result := GetRawTable('fpgm');
  Result.Position := 0;
end;

function TFontSubsetter.buildPrepTable: TStream;
begin
  Result := GetRawTable('prep');
  Result.Position := 0;
end;

function TFontSubsetter.buildCvtTable: TStream;
begin
  Result := GetRawTable('cvt ');
  Result.Position := 0;
end;

function TFontSubsetter.buildGlyfTable(var newOffsets: TArrayUInt32): TStream;
var
  n: integer;
  lOffset: uint32;
  lLen: uint32;
  gs: TMemoryStream;
  buf: TGlyphHeader;
  flags: uint16;
  glyphIndex: uint16;
begin
  lOffset := 0;
  Result := TMemoryStream.Create;
  LoadLocations;

  {  - Assign new glyph indexes
     - Retrieve glyph data in it doesn't yet exist (retrieved from original TTF file)
     - Now fix GlyphID references in Compound Glyphs to point to new GlyphIDs }
  for n := 0 to FGlyphIDList.Count-1 do
  begin
    FGlyphIDList[n].NewGlyphID := n;
    if not Assigned(FGlyphIDList[n].GlyphData) then
      FGlyphIDList[n].GlyphData := GetRawGlyphData(FGlyphIDList[n].GlyphID);
    if not FGlyphIDList[n].IsCompoundGlyph then
      Continue;
    {$IFDEF gDEBUG}
    writeln(Format('found compound glyph:  %.4x   glyphID: %d', [FGlyphIDList[n].CharID, FGlyphIDList[n].GlyphID]));
    {$ENDIF}
    gs := TMemoryStream(FGlyphIDList[n].GlyphData);
    gs.Position := 0;

    if gs.Size > 0 then
    begin
      FillMem(@buf, SizeOf(TGlyphHeader), 0);
      gs.ReadBuffer(buf, SizeOf(Buf));

      if buf.numberOfContours = -1 then
      begin
        repeat
          flags := ReadUInt16(gs);
          lOffset := gs.Position;
          glyphIndex := ReadUInt16(gs);
          // now write new GlyphID in it's place.
          gs.Position := lOffset;
          glyphIndex := FGlyphIDList.GetNewGlyphID(GetCharIDfromGlyphID(glyphIndex));
          WriteUInt16(gs, glyphIndex);

          // ARG_1_AND_2_ARE_WORDS
          if (flags and (1 shl 0)) <> 0 then
            ReadUInt32(gs)
          else
            ReadUInt16(gs);
          // WE_HAVE_A_TWO_BY_TWO
          if (flags and (1 shl 7)) <> 0 then
          begin
            ReadUInt32(gs);
            ReadUInt32(gs);
          end
          // WE_HAVE_AN_X_AND_Y_SCALE
          else if (flags and (1 shl 6)) <> 0 then
          begin
            ReadUInt32(gs);
          end
          // WE_HAVE_A_SCALE
          else if (flags and (1 shl 3)) <> 0 then
          begin
            ReadUInt16(gs);
          end;

        until (flags and (1 shl 5)) = 0;   // MORE_COMPONENTS
      end;  { if buf.numberOfContours = -1 }
    end;  { if gs.Size > 0 }
  end; { for n ... FGlyphIDList.Count-1 }

  // write all glyph data to resulting data stream
  lOffset := 0;
  for n := 0 to FGlyphIDList.Count-1 do
  begin
    newOffsets[n] := lOffset;
    lOffset := lOffset + FGlyphIDList[n].GlyphData.Size;
    FGlyphIDList[n].GlyphData.Position := 0;
    Result.CopyFrom(FGlyphIDList[n].GlyphData, FGlyphIDList[n].GlyphData.Size);
    // 4-byte alignment
    if (lOffset mod 4) <> 0 then
    begin
      lLen := 4 - (lOffset mod 4);
      Result.WriteBuffer(PAD_BUF, lLen);
      lOffset := lOffset + lLen;
    end;
  end;
  newOffsets[n+1] := lOffset;
end;

// write as UInt32 as defined in head.indexToLocFormat field (long format).
function TFontSubsetter.buildLocaTable(var newOffsets: TArrayUInt32): TStream;
var
  i: integer;
begin
  Result := TMemoryStream.Create;
  for i := 0 to Length(newOffsets)-1 do
    WriteUInt32(Result, newOffsets[i]);
end;

function TFontSubsetter.buildCmapTable: TStream;
const
    // platform
    PLATFORM_UNICODE = 0;
    PLATFORM_MACINTOSH = 1;
    // value 2 is reserved; do not use
    PLATFORM_WINDOWS = 3;

    // Mac encodings
    ENCODING_MAC_ROMAN = 0;

    // Windows encodings
    ENCODING_WIN_SYMBOL = 0; // Unicode, non-standard character set
    ENCODING_WIN_UNICODE_BMP = 1; // Unicode BMP (UCS-2)
    ENCODING_WIN_SHIFT_JIS = 2;
    ENCODING_WIN_BIG5 = 3;
    ENCODING_WIN_PRC = 4;
    ENCODING_WIN_WANSUNG = 5;
    ENCODING_WIN_JOHAB = 6;
    ENCODING_WIN_UNICODE_FULL = 10; // Unicode Full (UCS-4)

    // Unicode encodings
    ENCODING_UNICODE_1_0 = 0;
    ENCODING_UNICODE_1_1 = 1;
    ENCODING_UNICODE_2_0_BMP = 3;
    ENCODING_UNICODE_2_0_FULL = 4;
var
  segCount: UInt16;
  searchRange: UInt16;
  i: integer;
  startCode: Array of Integer;
  endCode: Array of Integer;
  idDelta: Array of Integer;
  lastChar: integer;
  prevChar: integer;
  lastGid: integer;
  itm: TTextMapping;
begin
  Result := TMemoryStream.Create;
  SetLength(startCode, FGlyphIDList.Count);
  SetLength(endCode, FGlyphIDList.Count);
  SetLength(idDelta, FGlyphIDList.Count);

  // cmap header
  WriteUInt16(Result, 0);  // version
  WriteUInt16(Result, 1);  // numberSubTables

  // encoding record
  WriteUInt16(Result, PLATFORM_WINDOWS);  // platformID
  WriteUInt16(Result, ENCODING_WIN_UNICODE_BMP);  // platformSpecificID
  WriteUInt32(Result, 4 * 2 + 4); // offset

  // build Format 4 subtable (Unicode BMP)
  lastChar := 0;
  prevChar := lastChar;
  lastGid  := FGlyphIDList[0].NewGlyphID;
  segCount := 0;

  for i := 0 to FGlyphIDList.Count-1 do
  begin
    itm := FGlyphIDList[i];
    if itm.CharID > $FFFF then
      raise Exception.Create('non-BMP Unicode character');

    if (itm.CharID <> FGlyphIDList[prevChar].CharID+1) or ((itm.NewGlyphID - lastGid) <> (itm.CharID - FGlyphIDList[lastChar].CharID)) then
    begin
      if (lastGid <> 0) then
      begin
        { don't emit ranges, which map to GID 0, the undef glyph is emitted at the very last segment }
        startCode[segCount] := FGlyphIDList[lastChar].CharID;
        endCode[segCount] := FGlyphIDList[prevChar].CharID;
        idDelta[segCount] := lastGid - FGlyphIDList[lastChar].CharID;
        inc(segCount);
      end
      else if not (FGlyphIDList[lastChar].CharID = FGlyphIDList[prevChar].CharID) then
      begin
        { shorten ranges which start with GID 0 by one }
        startCode[segCount] := FGlyphIDList[lastChar].CharID + 1;
        endCode[segCount] := FGlyphIDList[prevChar].CharID;
        idDelta[segCount] := lastGid - FGlyphIDList[lastChar].CharID;
        inc(segCount);
      end;
      lastGid := itm.NewGlyphID;
      lastChar := i;
    end;
    prevChar := i;
  end;

  // trailing segment
  startCode[segCount] := FGlyphIDList[lastChar].CharID;
  endCode[segCount] := FGlyphIDList[prevChar].CharID;
  idDelta[segCount] := lastGid - FGlyphIDList[lastChar].CharID;
  inc(segCount);

  // GID 0
  startCode[segCount] := $FFFF;
  endCode[segCount] := $FFFF;
  idDelta[segCount] := 1;
  inc(segCount);

  // write format 4 subtable
  searchRange := trunc(2 * Power(2, Floor(Log2(segCount))));
  WriteUInt16(Result, 4); // format
  WriteUInt16(Result, 8 * 2 + segCount * 4*2); // length
  WriteUInt16(Result, 0); // language
  WriteUInt16(Result, segCount * 2); // segCountX2
  WriteUInt16(Result, searchRange); // searchRange
  WriteUInt16(Result, trunc(log2(searchRange / 2))); // entrySelector
  WriteUInt16(Result, 2 * segCount - searchRange); // rangeShift

  // write endCode
  for i := 0 to segCount-1 do
    WriteUInt16(Result, endCode[i]);

  // reservedPad
  WriteUInt16(Result, 0);

  // startCode
  for i := 0 to segCount-1 do
    WriteUInt16(Result, startCode[i]);

  // idDelta
  for i := 0 to segCount-1 do
    WriteUInt16(Result, idDelta[i]);

  // idRangeOffset
  for i := 0 to segCount-1 do
    WriteUInt16(Result, 0);
end;

function TFontSubsetter.buildHmtxTable: TStream;
var
  n: integer;
begin
  Result := TMemoryStream.Create;
  for n := 0 to FGlyphIDList.Count-1 do
  begin
    WriteUInt16(Result, FFontInfo.Widths[FGlyphIDList[n].GlyphID].AdvanceWidth);
    WriteInt16(Result, FFontInfo.Widths[FGlyphIDList[n].GlyphID].LSB);
  end;
end;

constructor TFontSubsetter.Create(const AFont: TTFFileInfo; const AGlyphIDList: TTextMappingList);
begin
  FFontInfo := AFont;
  if not Assigned(FFontInfo) then
    raise ETTFSubsetter.Create(rsErrFontInfoNotAssigned);
  FGlyphIDList := AGlyphIDList;

  FKeepTables := TStringList.Create;
  FHasAddedCompoundReferences := False;
  FPrefix := '';
  FhasAddedCompoundReferences := False;

  // create a default list
  FKeepTables.Add('head');
  FKeepTables.Add('hhea');
  FKeepTables.Add('maxp');
  FKeepTables.Add('hmtx');
  FKeepTables.Add('cmap');
  FKeepTables.Add('fpgm');
  FKeepTables.Add('prep');
  FKeepTables.Add('cvt ');
  FKeepTables.Add('loca');
  FKeepTables.Add('glyf');

  if Assigned(FGlyphIDList) then
    FGlyphIDList.Sort;

  if FFontInfo.Filename <> '' then
    FStream := TFileStream.Create(FFontInfo.FileName, fmOpenRead or fmShareDenyNone)
  else
    raise ETTF.Create(rsErrCantFindFontFile);
end;

constructor TFontSubsetter.Create(const AFont: TTFFileInfo);
begin
  Create(AFont, nil);
end;

destructor TFontSubsetter.Destroy;
var
  i: integer;
begin
  // the owner of FGlyphIDList doesn't need the GlyphData information
  for i := 0 to FGlyphIDList.Count-1 do
    FGlyphIDList[i].GlyphData.Free;
  FStream.Free;
  FKeepTables.Free;
  inherited Destroy;
end;

procedure TFontSubsetter.SaveToFile(const AFileName: String);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    SaveToStream(fs);
  finally
    FreeAndNil(fs);
  end;
end;

procedure TFontSubsetter.SaveToStream(const AStream: TStream);
var
  checksum: uint64;
  offset: uint64;
  head: TStream;
  hhea: TStream;
  maxp: TStream;
  hmtx: TStream;
  cmap: TStream;
  fpgm: TStream;
  prep: TStream;
  cvt: TStream;
  loca: TStream;
  glyf: TStream;
  newLoca: TArrayUInt32;
  tables: TStringList;
  i: integer;
  o: uint64;
  p: uint64;
  lPadding: byte;
begin
  // resolve compound glyph references
  AddCompoundReferences;

  // always copy GID 0
  FGlyphIDList.Add(0, 0);
  FGlyphIDList.Sort;

  SetLength(newLoca, FGlyphIDList.Count+1);

  head := buildHeadTable();                // done
  hhea := buildHheaTable();                // done
  maxp := buildMaxpTable();                // done
  fpgm := buildFpgmTable();                // done
  prep := buildPrepTable();                // done
  cvt  := buildCvtTable();                 // done
  glyf := buildGlyfTable(newLoca);         // done
  loca := buildLocaTable(newLoca);         // done
  cmap := buildCmapTable();
  hmtx := buildHmtxTable();

  tables := TStringList.Create;
  tables.CaseSensitive := True;
  if Assigned(cmap) then
    tables.AddObject('cmap', cmap);
  if Assigned(glyf) then
    tables.AddObject('glyf', glyf);
  tables.AddObject('head', head);
  tables.AddObject('hhea', hhea);
  tables.AddObject('hmtx', hmtx);
  if Assigned(loca) then
    tables.AddObject('loca', loca);
  tables.AddObject('maxp', maxp);
  tables.AddObject('fpgm', fpgm);
  tables.AddObject('prep', prep);
  tables.AddObject('cvt ', cvt);
  tables.Sort;

  // calculate checksum
  checksum := writeFileHeader(AStream, tables.Count);
  offset := 12 + (16 * tables.Count);
  lPadding := 0;
  for i := 0 to tables.Count-1 do
  begin
    if tables.Objects[i] <> nil then
    begin
      checksum := checksum + WriteTableHeader(AStream, tables.Strings[i], offset, TStream(tables.Objects[i]));
      p := TStream(tables.Objects[i]).Size;
      // table bodies must be 4-byte aligned - calculate the padding so the tableHeader.Offset field can reflect that.
      if (p mod 4) = 0 then
        lPadding := 0
      else
        lPadding := 4 - (p mod 4);
      o := p + lPadding;
      offset := offset + o;
    end;
  end;
  checksum := $B1B0AFBA - (checksum and $ffffffff);

  // update head.ChecksumAdjustment field
  head.Seek(8, soBeginning);
  WriteUInt32(head, checksum);

  // write table bodies
  WriteTableBodies(AStream, tables);

  for i := 0 to tables.Count-1 do
    TStream(tables.Objects[i]).Free;
  tables.Free;
end;

procedure TFontSubsetter.Add(const ACodePoint: uint32);
var
  gid: uint32;
begin
  gid := FFontInfo.Chars[ACodePoint];
  if gid <> 0 then
    FGlyphIDList.Add(ACodePoint, FFontInfo.Chars[ACodePoint]);
end;


end.
