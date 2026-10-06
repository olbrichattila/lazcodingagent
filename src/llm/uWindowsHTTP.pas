unit uWindowsHTTP;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ Uses the Windows HTTP stack (and its native Schannel TLS implementation). }
procedure WindowsHTTPRequest(const AMethod, AURL: string; AHeaders: TStrings;
  const ABody: RawByteString; AResponse: TStream; out AStatusCode: Integer);

implementation

{$IFDEF MSWINDOWS}
uses
  Windows;

type
  HInternet = Pointer;

function WinHttpOpen(pwszUserAgent: PWideChar; dwAccessType: DWORD;
  pwszProxyName, pwszProxyBypass: PWideChar; dwFlags: DWORD): HInternet; stdcall;
  external 'winhttp.dll' name 'WinHttpOpen';
function WinHttpConnect(hSession: HInternet; pswzServerName: PWideChar;
  nServerPort: Word; dwReserved: DWORD): HInternet; stdcall;
  external 'winhttp.dll' name 'WinHttpConnect';
function WinHttpOpenRequest(hConnect: HInternet; pwszVerb, pwszObjectName,
  pwszVersion, pwszReferrer: PWideChar; ppwszAcceptTypes: Pointer;
  dwFlags: DWORD): HInternet; stdcall; external 'winhttp.dll' name 'WinHttpOpenRequest';
function WinHttpSendRequest(hRequest: HInternet; pwszHeaders: PWideChar;
  dwHeadersLength: DWORD; lpOptional: Pointer; dwOptionalLength,
  dwTotalLength: DWORD_PTR; dwContext: DWORD_PTR): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpSendRequest';
function WinHttpReceiveResponse(hRequest: HInternet; lpReserved: Pointer): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpReceiveResponse';
function WinHttpQueryHeaders(hRequest: HInternet; dwInfoLevel: DWORD;
  pwszName: PWideChar; lpBuffer: Pointer; var lpdwBufferLength: DWORD;
  var lpdwIndex: DWORD): BOOL; stdcall; external 'winhttp.dll' name 'WinHttpQueryHeaders';
function WinHttpReadData(hRequest: HInternet; lpBuffer: Pointer;
  dwNumberOfBytesToRead: DWORD; var lpdwNumberOfBytesRead: DWORD): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpReadData';
function WinHttpSetTimeouts(hInternet: HInternet; nResolveTimeout,
  nConnectTimeout, nSendTimeout, nReceiveTimeout: Integer): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpSetTimeouts';
function WinHttpCloseHandle(hInternet: HInternet): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpCloseHandle';

const
  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0;
  WINHTTP_FLAG_SECURE = $00800000;
  WINHTTP_QUERY_STATUS_CODE = 19;
  WINHTTP_QUERY_FLAG_NUMBER = $20000000;

procedure ParseURL(const AURL: string; out AHost, APath: string;
  out APort: Word; out ASecure: Boolean);
var
  S, Authority, PortText: string;
  P, SlashPos, QueryPos, ColonPos: SizeInt;
begin
  S := Trim(AURL);
  if SameText(Copy(S, 1, 8), 'https://') then
  begin
    ASecure := True;
    APort := 443;
    Delete(S, 1, 8);
  end
  else if SameText(Copy(S, 1, 7), 'http://') then
  begin
    ASecure := False;
    APort := 80;
    Delete(S, 1, 7);
  end
  else
    raise Exception.Create('Endpoint URL must begin with http:// or https://');

  SlashPos := Pos('/', S);
  QueryPos := Pos('?', S);
  if (SlashPos = 0) or ((QueryPos > 0) and (QueryPos < SlashPos)) then
  begin
    if QueryPos > 0 then P := QueryPos else P := Length(S) + 1;
  end
  else
    P := SlashPos;
  Authority := Copy(S, 1, P - 1);
  APath := Copy(S, P, MaxInt);
  if APath = '' then APath := '/'
  else if APath[1] = '?' then APath := '/' + APath;
  P := Pos('#', APath);
  if P > 0 then Delete(APath, P, MaxInt);

  { URL user-info is not supported; API credentials belong in Authorization. }
  if Pos('@', Authority) > 0 then
    raise Exception.Create('User information is not supported in the endpoint URL');
  AHost := Authority;
  PortText := '';
  if (Authority <> '') and (Authority[1] = '[') then
  begin
    P := Pos(']', Authority);
    if P = 0 then raise Exception.Create('Invalid IPv6 endpoint URL');
    AHost := Copy(Authority, 2, P - 2);
    if (P < Length(Authority)) and (Authority[P + 1] = ':') then
      PortText := Copy(Authority, P + 2, MaxInt);
  end
  else
  begin
    ColonPos := LastDelimiter(':', Authority);
    if ColonPos > 0 then
    begin
      AHost := Copy(Authority, 1, ColonPos - 1);
      PortText := Copy(Authority, ColonPos + 1, MaxInt);
    end;
  end;
  if AHost = '' then raise Exception.Create('Endpoint URL has no host');
  if PortText <> '' then
  begin
    P := StrToIntDef(PortText, 0);
    if (P < 1) or (P > 65535) then
      raise Exception.Create('Endpoint URL has an invalid port');
    APort := P;
  end;
end;

procedure WindowsHTTPRequest(const AMethod, AURL: string; AHeaders: TStrings;
  const ABody: RawByteString; AResponse: TStream; out AStatusCode: Integer);
var
  Host, Path, HeaderText: string;
  HostW, PathW, MethodW, HeaderW, AgentW: UnicodeString;
  Port: Word;
  Secure: Boolean;
  Session, Connection, Request: HInternet;
  I: Integer;
  BytesRead, BufferLength, HeaderIndex: DWORD;
  Buffer: array[0..16383] of Byte;
  BodyPtr: Pointer;
begin
  AStatusCode := 0;
  Session := nil; Connection := nil; Request := nil;
  ParseURL(AURL, Host, Path, Port, Secure);
  HostW := UTF8Decode(Host);
  PathW := UTF8Decode(Path);
  MethodW := UTF8Decode(AMethod);
  AgentW := 'LazarusCodingAgent';
  if Assigned(AHeaders) then
    for I := 0 to AHeaders.Count - 1 do
      HeaderText := HeaderText + AHeaders[I] + #13#10;
  HeaderW := UTF8Decode(HeaderText);
  if ABody = '' then BodyPtr := nil else BodyPtr := Pointer(ABody);
  try
    Session := WinHttpOpen(PWideChar(AgentW), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
      nil, nil, 0);
    if Session = nil then RaiseLastOSError;
    if not WinHttpSetTimeouts(Session, 30000, 30000, 120000, 120000) then
      RaiseLastOSError;
    Connection := WinHttpConnect(Session, PWideChar(HostW), Port, 0);
    if Connection = nil then RaiseLastOSError;
    if Secure then
      Request := WinHttpOpenRequest(Connection, PWideChar(MethodW),
        PWideChar(PathW), nil, nil, nil, WINHTTP_FLAG_SECURE)
    else
      Request := WinHttpOpenRequest(Connection, PWideChar(MethodW),
        PWideChar(PathW), nil, nil, nil, 0);
    if Request = nil then RaiseLastOSError;

    if HeaderW = '' then
    begin
      if not WinHttpSendRequest(Request, nil, 0, BodyPtr, Length(ABody),
        Length(ABody), 0) then RaiseLastOSError;
    end
    else if not WinHttpSendRequest(Request, PWideChar(HeaderW), DWORD(-1),
      BodyPtr, Length(ABody), Length(ABody), 0) then
      RaiseLastOSError;
    if not WinHttpReceiveResponse(Request, nil) then RaiseLastOSError;

    BufferLength := SizeOf(AStatusCode);
    HeaderIndex := 0;
    if not WinHttpQueryHeaders(Request,
      WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER, nil,
      @AStatusCode, BufferLength, HeaderIndex) then RaiseLastOSError;

    if Assigned(AResponse) then
      repeat
        BytesRead := 0;
        if not WinHttpReadData(Request, @Buffer[0], SizeOf(Buffer), BytesRead) then
          RaiseLastOSError;
        if BytesRead > 0 then AResponse.WriteBuffer(Buffer[0], BytesRead);
      until BytesRead = 0;
  finally
    if Request <> nil then WinHttpCloseHandle(Request);
    if Connection <> nil then WinHttpCloseHandle(Connection);
    if Session <> nil then WinHttpCloseHandle(Session);
  end;
end;

{$ELSE}

procedure WindowsHTTPRequest(const AMethod, AURL: string; AHeaders: TStrings;
  const ABody: RawByteString; AResponse: TStream; out AStatusCode: Integer);
begin
  AStatusCode := 0;
  raise Exception.Create('Windows HTTP transport is available only on Windows');
end;

{$ENDIF}

end.
