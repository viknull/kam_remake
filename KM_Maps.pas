unit KM_Maps;
{$I KaM_Remake.inc}
interface
uses
  Classes, KromUtils, Math, SyncObjs, SysUtils, KM_GameInfo;


type
  TMapsSortMethod = (
    smByNameAsc, smByNameDesc,
    smBySizeAsc, smBySizeDesc,
    smByPlayersAsc, smByPlayersDesc,
    smByModeAsc, smByModeDesc);

  TKMapInfo = class;
  TMapEvent = procedure (aMap: TKMapInfo) of object;

  TKMapInfo = class
  private
    fInfo: TKMGameInfo;
    fPath: string;
    fFileName: string; //without extension
    fDefaultHuman: ShortInt;
    fStrictParsing: Boolean; //Use strict map checking, important for MP
    fDatSize: Integer;
    fCRC: Cardinal;
    procedure ScanMap;
    procedure LoadFromFile(const aPath: string);
    procedure SaveToFile(const aPath: string);
  public
    Author, SmallDesc, BigDesc: string;
    IsCoop: Boolean; //Some multiplayer missions are defined as coop

    constructor Create;
    destructor Destroy; override;

    procedure Load(const aFolder: string; aStrictParsing, aIsMultiplayer: Boolean);

    property Info: TKMGameInfo read fInfo;
    property Path: string read fPath;
    property FileName: string read fFileName;
    function FullPath(const aExt: string): string;
    property CRC: Cardinal read fCRC;
    property DefaultHuman: ShortInt read fDefaultHuman;

    function IsValid: Boolean;
  end;

  TTMapsScanner = class(TThread)
  private
    fMultiplayerPath: Boolean;
    fOnMapAdd: TMapEvent;
    fOnMapAddDone: TNotifyEvent;
  public
    constructor Create(aMultiplayerPath: Boolean; aOnMapAdd: TMapEvent; aOnMapAddDone, aOnComplete: TNotifyEvent);
    procedure Execute; override;
  end;

  TKMapsCollection = class
  private
    fCount: Integer;
    fMaps: array of TKMapInfo;
    fMultiplayerPath: Boolean;
    fSortMethod: TMapsSortMethod;
    CS: TCriticalSection;
    fScanner: TTMapsScanner;
    fScanning: Boolean; //Flag if scan is in progress
    fUpdateNeeded: Boolean;
    fOnRefresh: TNotifyEvent;
    procedure Clear;
    procedure MapAdd(aMap: TKMapInfo);
    procedure MapAddDone(Sender: TObject);
    procedure ScanComplete(Sender: TObject);
    procedure DoSort;
    function GetMap(aIndex: Integer): TKMapInfo;
  public
    constructor Create(aMultiplayerPath: Boolean; aSortMethod: TMapsSortMethod = smByNameDesc);
    destructor Destroy; override;

    property Count: Integer read fCount;
    property Maps[aIndex: Integer]: TKMapInfo read GetMap; default;
    procedure Lock;
    procedure Unlock;

    class function FullPath(const aName, aExt: string; aMultiplayer: Boolean): string;

    procedure Refresh(aOnRefresh: TNotifyEvent);
    procedure TerminateScan;
    procedure Sort(aSortMethod: TMapsSortMethod; aOnSortComplete: TNotifyEvent);
    property SortMethod: TMapsSortMethod read fSortMethod; //Read-only because we should not change it while Refreshing

    //Should be accessed only as a part of aOnRefresh/aOnSort events handlers
    function MapList: string;
    procedure UpdateState;
  end;


implementation
uses KM_CommonClasses, KM_Defaults, KM_MissionScript_Info, KM_Player, KM_TextLibrary;


const
  //Folder name containing single maps for SP/MP mode
  MAP_FOLDER_MP: array [Boolean] of string = ('Maps', 'MapsMP');


{ TKMapInfo }
constructor TKMapInfo.Create;
begin
  inherited;
  fInfo := TKMGameInfo.Create;
end;


destructor TKMapInfo.Destroy;
begin
  fInfo.Free;
  inherited;
end;


function TKMapInfo.FullPath(const aExt: string): string;
begin
  Result := fPath + fFileName + aExt;
end;


procedure TKMapInfo.Load(const aFolder:string; aStrictParsing, aIsMultiplayer: Boolean);
begin
  fPath := ExeDir + MAP_FOLDER_MP[aIsMultiplayer] + '\' + aFolder + '\';
  fFileName := aFolder;

  fStrictParsing := aStrictParsing;
  ScanMap;
end;


procedure TKMapInfo.ScanMap;
var
  st,DatFile,MapFile:string;
  ft:textfile;
  I: Integer;
  fMissionParser: TMissionParserInfo;
begin
  //We scan only single-player maps which are in Maps\ folder, so DAT\MAP paths are straight
  DatFile := fPath + fFileName + '.dat';
  MapFile := fPath + fFileName + '.map';

  LoadFromFile(fPath + fFileName + '.mi'); //Data will be empty if failed

  //We will scan map once again if anything has changed
  //In SP mode we check DAT size and version, that is enough
  //In MP mode we also need exact CRCs to match maps between players
  if FileExists(DatFile) then
  if (fDatSize <> GetFileSize(DatFile)) or
     (fInfo.Version <> GAME_REVISION) or
     (fStrictParsing and (fCRC <> Adler32CRC(DatFile) xor Adler32CRC(MapFile)))
  then
  begin
    fDatSize := GetFileSize(DatFile);

    fMissionParser := TMissionParserInfo.Create(false);
    try
      fMissionParser.LoadMission(DatFile);

      //Single maps Titles are the same as FileName for now.
      //Campaign maps are in different folder
      fInfo.Title             := FileName;
      fInfo.Version           := GAME_REVISION;
      fInfo.TickCount         := 0;
      fInfo.MissionMode       := fMissionParser.MissionInfo.MissionMode;
      fInfo.MapSizeX          := fMissionParser.MissionInfo.MapSizeX;
      fInfo.MapSizeY          := fMissionParser.MissionInfo.MapSizeY;
      fInfo.VictoryCondition  := fMissionParser.MissionInfo.VictoryCond;
      fInfo.DefeatCondition   := fMissionParser.MissionInfo.DefeatCond;
      fDefaultHuman := fMissionParser.MissionInfo.DefaultHuman;

      //This feature is only used for saves yet
      fInfo.PlayerCount       := fMissionParser.MissionInfo.PlayerCount;
      for I := Low(fInfo.LocationName) to High(fInfo.LocationName) do
      begin
        fInfo.CanBeHuman[I] := fMissionParser.MissionInfo.PlayerHuman[I];
        fInfo.LocationName[I] := Format(fTextLibrary[TX_LOBBY_LOCATION_X], [I+1]);
        fInfo.PlayerTypes[I] := TPlayerType(-1);
        fInfo.ColorID[I] := 0;
        fInfo.Team[I] := 0;
      end;

      fCRC := Adler32CRC(DatFile) xor Adler32CRC(MapFile);

      SaveToFile(fPath + fFileName + '.mi'); //Save new TMP file
    finally
      fMissionParser.Free;
    end;
  end;

  //Load additional text info
  if FileExists(fPath + fFileName + '.txt') then
  begin
    AssignFile(ft, fPath + fFileName + '.txt');
    FileMode := fmOpenRead;
    Reset(ft);
    repeat
      ReadLn(ft,st);
      if SameText(st, 'Author')    then ReadLn(ft, Author);
      if SameText(st, 'SmallDesc') then ReadLn(ft, SmallDesc);
      if SameText(st, 'BigDesc')   then ReadLn(ft, BigDesc);
      if SameText(st, 'SetCoop')   then IsCoop := True;
    until(eof(ft));
    CloseFile(ft);
  end;
end;


procedure TKMapInfo.LoadFromFile(const aPath: string);
var
  S: TKMemoryStream;
  I: Integer;
begin
  if not FileExists(aPath) then Exit;

  S := TKMemoryStream.Create;
  S.LoadFromFile(aPath);
  fInfo.Load(S);
  S.Read(fCRC);
  S.Read(fDefaultHuman);
  S.Read(fDatSize);
  S.Free;

  //We need to reset all of the location names since otherwise they could be
  //in another language (when .mi files are zipped up with the map and sent
  //to another person)
  for I := Low(fInfo.LocationName) to High(fInfo.LocationName) do
    fInfo.LocationName[I] := Format(fTextLibrary[TX_LOBBY_LOCATION_X], [I+1]);
end;


procedure TKMapInfo.SaveToFile(const aPath: string);
var S: TKMemoryStream;
begin
  S := TKMemoryStream.Create;
  try
    fInfo.Save(S);
    S.Write(fCRC);
    S.Write(fDefaultHuman);
    S.Write(fDatSize);
    S.SaveToFile(aPath);
  finally
    S.Free;
  end;
end;


function TKMapInfo.IsValid: Boolean;
begin
  Result := fInfo.IsValid(False) and
            FileExists(fPath + fFileName + '.dat') and
            FileExists(fPath + fFileName + '.map');
end;


{ TKMapsCollection }
constructor TKMapsCollection.Create(aMultiplayerPath: Boolean; aSortMethod: TMapsSortMethod = smByNameDesc);
begin
  inherited Create;
  fMultiplayerPath := aMultiplayerPath;
  fSortMethod := aSortMethod;

  //CS is used to guard sections of code to allow only one thread at once to access them
  //We mostly don't need it, as UI should access Maps only when map events are signaled
  //it mostly acts as a safenet
  CS := TCriticalSection.Create;
end;


destructor TKMapsCollection.Destroy;
begin
  //Terminate and release the Scanner if we have one working or finished
  TerminateScan;

  //Release TKMapInfo objects
  Clear;

  CS.Free;
  inherited;
end;


function TKMapsCollection.GetMap(aIndex: Integer): TKMapInfo;
begin
  //No point locking/unlocking here since we return a TObject that could be modified/freed
  //by another thread before the caller uses it.
  Assert(InRange(aIndex, 0, fCount - 1));
  Result := fMaps[aIndex];
end;


procedure TKMapsCollection.Lock;
begin
  CS.Enter;
end;


procedure TKMapsCollection.Unlock;
begin
  CS.Leave;
end;


function TKMapsCollection.MapList: string;
var I: Integer;
begin
  Lock;
    Result := '';
    for I := 0 to fCount - 1 do
      Result := Result + fMaps[I].FileName + eol;
  Unlock;
end;


procedure TKMapsCollection.Clear;
var
  I: Integer;
begin
  Assert(not fScanning, 'Guarding from access to inconsistent data');
  for I := 0 to fCount - 1 do
    FreeAndNil(fMaps[I]);
  fCount := 0;
end;


procedure TKMapsCollection.UpdateState;
begin
  if fUpdateNeeded then
  begin
    if Assigned(fOnRefresh) then
      fOnRefresh(Self);

    fUpdateNeeded := False;
  end;
end;


//For private acces, where CS is managed by the caller
procedure TKMapsCollection.DoSort;
  //Return True if items should be exchanged
  function Compare(A, B: TKMapInfo; aMethod: TMapsSortMethod): Boolean;
  begin
    Result := False; //By default everything remains in place
    case aMethod of
      smByNameAsc:      Result := CompareText(A.Info.Title, B.Info.Title) < 0;
      smByNameDesc:     Result := CompareText(A.Info.Title, B.Info.Title) > 0;
      smBySizeAsc:      Result := (A.Info.MapSizeX * A.Info.MapSizeY) < (B.Info.MapSizeX * B.Info.MapSizeY);
      smBySizeDesc:     Result := (A.Info.MapSizeX * A.Info.MapSizeY) > (B.Info.MapSizeX * B.Info.MapSizeY);
      smByPlayersAsc:   Result := A.Info.PlayerCount < B.Info.PlayerCount;
      smByPlayersDesc:  Result := A.Info.PlayerCount > B.Info.PlayerCount;
      smByModeAsc:      Result := A.Info.MissionMode < B.Info.MissionMode;
      smByModeDesc:     Result := A.Info.MissionMode > B.Info.MissionMode;
    end;
  end;
var
  I, K: Integer;
begin
  for I := 0 to fCount - 1 do
  for K := I to fCount - 1 do
  if Compare(fMaps[I], fMaps[K], fSortMethod) then
    SwapInt(Cardinal(fMaps[I]), Cardinal(fMaps[K])); //Exchange only pointers to MapInfo objects
end;


//For public access
//Apply new Sort within Critical Section, as we could be in the Refresh phase
//note that we need to preserve fScanning flag
procedure TKMapsCollection.Sort(aSortMethod: TMapsSortMethod; aOnSortComplete: TNotifyEvent);
begin
  Lock;
  try
    if fScanning then
    begin
      fScanning := False;
      fSortMethod := aSortMethod;
      DoSort;
      if Assigned(aOnSortComplete) then
        aOnSortComplete(Self);
      fScanning := True;
    end
    else
    begin
      fSortMethod := aSortMethod;
      DoSort;
      if Assigned(aOnSortComplete) then
        aOnSortComplete(Self);
    end;
  finally
    Unlock;
  end;
end;


procedure TKMapsCollection.TerminateScan;
begin
  if (fScanner <> nil) then
  begin
    fScanner.Terminate;
    fScanner.WaitFor;
    fScanner.Free;
    fScanner := nil;
    fScanning := False;
  end;
end;


//Start the refresh of maplist
procedure TKMapsCollection.Refresh(aOnRefresh: TNotifyEvent);
begin
  //Terminate previous Scanner if two scans were launched consequentialy
  TerminateScan;
  Clear;

  fOnRefresh := aOnRefresh;

  //Scan will launch upon create automatcally
  fScanning := True;
  fScanner := TTMapsScanner.Create(fMultiplayerPath, MapAdd, MapAddDone, ScanComplete);
end;


procedure TKMapsCollection.MapAdd(aMap: TKMapInfo);
begin
  Lock;
  try
    SetLength(fMaps, fCount + 1);
    fMaps[fCount] := aMap;
    Inc(fCount);

    //Set the scanning to false so we could Sort
    fScanning := False;

    //Keep the maps sorted
    //We signal from Locked section, so everything caused by event can safely access our Maps
    DoSort;

    fScanning := True;
  finally
    Unlock;
  end;
end;


procedure TKMapsCollection.MapAddDone(Sender: TObject);
begin
  fUpdateNeeded := True; //Next time the GUI thread calls UpdateState we will run fOnRefresh
end;


//All maps have been scanned
//No need to resort since that was done in last MapAdd event
procedure TKMapsCollection.ScanComplete(Sender: TObject);
begin
  Lock;
  try
    fScanning := False;
  finally
    Unlock;
  end;
end;


class function TKMapsCollection.FullPath(const aName, aExt: string; aMultiplayer: Boolean): string;
begin
  Result := ExeDir + MAP_FOLDER_MP[aMultiplayer] + '\' + aName + '\' + aName + aExt;
end;


{ TTMapsScanner }
//aOnMapAdd - signal that there's new map that should be added
//aOnMapAddDone - signal that map has been added
//aOnComplete - scan is complete
constructor TTMapsScanner.Create(aMultiplayerPath: Boolean; aOnMapAdd: TMapEvent; aOnMapAddDone, aOnComplete: TNotifyEvent);
begin
  //Thread isn't started until all constructors have run to completion
  //so Create(False) may be put in front as well
  inherited Create(False);

  Assert(Assigned(aOnMapAdd));

  fMultiplayerPath := aMultiplayerPath;
  fOnMapAdd := aOnMapAdd;
  fOnMapAddDone := aOnMapAddDone;
  OnTerminate := aOnComplete;
  FreeOnTerminate := False;
end;


procedure TTMapsScanner.Execute;
var
  SearchRec: TSearchRec;
  PathToMaps: string;
  Map: TKMapInfo;
begin
  PathToMaps := ExeDir + MAP_FOLDER_MP[fMultiplayerPath] + '\';

  if not DirectoryExists(PathToMaps) then Exit;

  FindFirst(PathToMaps + '*', faDirectory, SearchRec);
  repeat
    if (SearchRec.Name <> '.') and (SearchRec.Name <> '..')
    and FileExists(TKMapsCollection.FullPath(SearchRec.Name, '.dat', fMultiplayerPath))
    and FileExists(TKMapsCollection.FullPath(SearchRec.Name, '.map', fMultiplayerPath)) then
    begin
      Map := TKMapInfo.Create;
      Map.Load(SearchRec.Name, false, fMultiplayerPath);
      if SLOW_MAP_SCAN then
        Sleep(50);
      fOnMapAdd(Map);
      fOnMapAddDone(Self);
    end;
  until (FindNext(SearchRec) <> 0) or Terminated;
  FindClose(SearchRec);
end;


end.

