// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Sanitizer;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.RegularExpressions,
  DevFormel.Trace.Types;

type
  /// <summary>A rule added with <c>TDFPIISanitizer.AddScrubRule</c>.</summary>
  /// <exclude/>
  TDFScrubRule = record
    /// <summary>Compiled pattern.</summary>
    Regex: TRegEx;
    /// <summary>Replacement text; may refer to groups with $1, $2 and so on.</summary>
    Replacement: string;
  end;

type
  /// <summary>
  /// Removes personal data and secrets from text and events.
  /// </summary>
  /// <remarks>
  /// TDFTraceHub calls ScrubEvent in its background thread when EnablePIIScrubbing is True.
  /// All methods are thread-safe; calls are serialized internally.
  /// Detection is based on patterns, so there is no guarantee that all personal data and
  /// secrets are removed. Not detected: names of people other than the current Windows user,
  /// postal addresses, phone numbers, customer or account numbers, IPv6 addresses and file
  /// names. Add rules for data of your own application with AddSecretKey and AddScrubRule,
  /// and check what your application passes to the hub.
  /// Version numbers with four parts, such as 2.1.0.12, look like IPv4 addresses and are
  /// replaced as well.
  /// </remarks>
  TDFPIISanitizer = class
  private
    class var FSecretKeys: TArray<string>;
    class var FCustomRules: TArray<TDFScrubRule>;
    class var FSecretValueRegex: TRegEx;
    class var FBearerRegex: TRegEx;
    class var FEmailRegex: TRegEx;
    class var FIPv4Regex: TRegEx;
    class var FWinUserPathRegex: TRegEx;
    class var FUnixUserPathRegex: TRegEx;
    class var FUserNameRegex: TRegEx;
    class var FHasUserNameRegex: Boolean;
    class var FComputerNameRegex: TRegEx;
    class var FHasComputerNameRegex: Boolean;
    class var FLock: TCriticalSection;
    class constructor Create;
    class destructor Destroy;
    class function CreateNameRegex(const AName: string; out ARegex: TRegEx): Boolean; static;
    class function IsSecretKey(const AKey: string): Boolean; static;
    class procedure BuildSecretValueRegex; static;
  public
    /// <summary>
    /// Replaces personal data and secrets in a text.
    /// </summary>
    /// <param name="AInput">Text that may contain personal data.</param>
    /// <returns>
    /// The text with e-mail addresses, IPv4 addresses, user names in user directory paths,
    /// values after secret keys (such as password=, token=, api_key=, Bearer) and the current
    /// user and computer name replaced. If the text cannot be checked, the result is
    /// [REDACTED].
    /// </returns>
    class function ScrubText(const AInput: string): string; static;

    /// <summary>
    /// Replaces personal data and secrets in message, exception message, stack trace,
    /// breadcrumbs, tags and extra values of an event.
    /// </summary>
    /// <param name="AEvent">The event, changed in place.</param>
    /// <remarks>
    /// Values of tags and extra entries whose key names a secret (for example Password,
    /// ApiKey, AuthToken, ClientSecret) are replaced completely. A replaced number or boolean
    /// becomes text. AppName, Environment and AppVersion are not changed. If the event cannot
    /// be checked, both messages become [REDACTED], and stack trace, breadcrumbs, tags and
    /// extra values are removed.
    /// </remarks>
    class procedure ScrubEvent(var AEvent: TDFTraceEvent); static;

    /// <summary>
    /// Adds a field name whose values are always replaced, whatever they look like.
    /// </summary>
    /// <param name="AKey">Field name, for example 'pin' or 'SessionId'. Case is ignored.</param>
    /// <remarks>
    /// In text, the value after key=, key: or "key":" is replaced. Tags and extra entries with
    /// exactly this key are replaced completely. The setting applies to all hubs; call it once
    /// at program start. General names such as 'name' or 'id' hide a lot of information.
    /// </remarks>
    class procedure AddSecretKey(const AKey: string); static;

    /// <summary>
    /// Adds a regular expression whose matches are replaced in all scrubbed text.
    /// </summary>
    /// <param name="APattern">PCRE pattern. Use (?i) at the start to ignore case.</param>
    /// <param name="AReplacement">Replacement text; may refer to groups with $1, $2 and so on.</param>
    /// <remarks>
    /// For data that can be recognized by its content, for example
    /// <c>AddScrubRule('\bDE\d{20}\b', '[IBAN_REDACTED]')</c>. Own rules run after the secret
    /// keys and before the built-in patterns, so they see the original text. The setting applies
    /// to all hubs; call it once at program start. An invalid pattern raises an exception here.
    /// The pattern runs on every text of every event, on up to 8,000 characters each. A
    /// pattern with nested repetitions, such as (\w+\s?)+, can take seconds on a long text
    /// and delays all events during that time; test own patterns with long texts.
    /// </remarks>
    class procedure AddScrubRule(const APattern, AReplacement: string); static;
  end;

implementation

const
  Redacted = '[REDACTED]';
  // Keys whose values are secret, whatever the value looks like. Passwort and Kennwort
  // because many Delphi applications name their fields in German.
  BuiltInSecretKeys: array[0..13] of string = ('password', 'passwd', 'pwd', 'passwort',
    'kennwort', 'secret', 'client_secret', 'token', 'access_token', 'refresh_token', 'id_token',
    'api_key', 'apikey', 'api-key');
  // Shorter names would also match ordinary words too often
  MinNameLength = 3;

{ TDFPIISanitizer }

class constructor TDFPIISanitizer.Create;
begin
  FLock := TCriticalSection.Create;

  FSecretKeys := nil;
  FCustomRules := nil;
  BuildSecretValueRegex;
  FBearerRegex := TRegEx.Create('\b(Bearer\s+)[A-Za-z0-9\-._~+/]+=*', [roCompiled, roIgnoreCase]);
  // \p{L} for addresses with umlauts, %40 for addresses in URLs.
  // An address may only start where the character before it cannot belong to it, or where
  // the previous match ended (\G). Without this, a long text without spaces is searched
  // again from each of its characters, and the time grows with the square of its length.
  FEmailRegex := TRegEx.Create('(?:\G|(?<![\p{L}\p{N}._%+-]))' +
    '[\p{L}\p{N}._%+-]+(?:@|%40)[\p{L}\p{N}.-]+\.\p{L}{2,}',
    [roCompiled, roIgnoreCase]);
  FIPv4Regex := TRegEx.Create('\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b', [roCompiled]);
  FWinUserPathRegex := TRegEx.Create('([a-zA-Z]:\\Users\\)([^\\]+)', [roCompiled, roIgnoreCase]);
  FUnixUserPathRegex := TRegEx.Create('(\/(?:home|Users)\/)([^\/]+)', [roCompiled, roIgnoreCase]);

  // The user name also appears outside of C:\Users, for example in \\server\home$\<user>
{$IFDEF MSWINDOWS}
  FHasUserNameRegex := CreateNameRegex(GetEnvironmentVariable('USERNAME'), FUserNameRegex);
  FHasComputerNameRegex := CreateNameRegex(GetEnvironmentVariable('COMPUTERNAME'), FComputerNameRegex);
{$ELSE}
  FHasUserNameRegex := CreateNameRegex(GetEnvironmentVariable('USER'), FUserNameRegex);
  FHasComputerNameRegex := CreateNameRegex(GetEnvironmentVariable('HOSTNAME'), FComputerNameRegex);
{$ENDIF}
end;

class destructor TDFPIISanitizer.Destroy;
begin
  FreeAndNil(FLock);
end;

class procedure TDFPIISanitizer.BuildSecretValueRegex;
var
  Pattern, Key: string;
begin
  Pattern := '';
  for Key in BuiltInSecretKeys do
    Pattern := Pattern + '|' + TRegEx.Escape(Key);
  for Key in FSecretKeys do
    Pattern := Pattern + '|' + TRegEx.Escape(Key);
  Delete(Pattern, 1, 1);

  // key=value, key: value and "key":"value". The value ends at whitespace, a quote, ; , or &
  FSecretValueRegex := TRegEx.Create('\b(' + Pattern + ')("?\s*[=:]\s*"?)[^\s;&"'',]+',
    [roCompiled, roIgnoreCase]);
end;

class procedure TDFPIISanitizer.AddSecretKey(const AKey: string);
var
  Key, Existing: string;
begin
  Key := AKey.Trim.ToLower;
  if Key.IsEmpty then Exit;

  FLock.Enter;
  try
    for Existing in FSecretKeys do
      if Existing = Key then Exit;
    FSecretKeys := FSecretKeys + [Key];
    BuildSecretValueRegex;
  finally
    FLock.Leave;
  end;
end;

class procedure TDFPIISanitizer.AddScrubRule(const APattern, AReplacement: string);
var
  Rule: TDFScrubRule;
begin
  // Compiled here, so that an invalid pattern fails at the call and not later in the worker
  Rule.Regex := TRegEx.Create(APattern, [roCompiled]);
  Rule.Replacement := AReplacement;

  FLock.Enter;
  try
    FCustomRules := FCustomRules + [Rule];
  finally
    FLock.Leave;
  end;
end;

class function TDFPIISanitizer.CreateNameRegex(const AName: string; out ARegex: TRegEx): Boolean;
var
  Name: string;
begin
  Name := AName.Trim;
  Result := Length(Name) >= MinNameLength;
  if Result then
    // Whole words only: "anna" must not hit "Johanna"
    ARegex := TRegEx.Create('(?<![\p{L}\p{N}_])' + TRegEx.Escape(Name) + '(?![\p{L}\p{N}_])',
      [roCompiled, roIgnoreCase]);
end;

class function TDFPIISanitizer.IsSecretKey(const AKey: string): Boolean;
var
  Key, Custom: string;
begin
  // Suffixes also cover keys such as DbPassword, ClientSecret or AuthToken
  Key := AKey.Trim.ToLower;
  Result := (Key = 'pwd') or Key.EndsWith('password') or Key.EndsWith('passwd') or
    Key.EndsWith('passwort') or Key.EndsWith('kennwort') or
    Key.EndsWith('secret') or Key.EndsWith('token') or Key.EndsWith('apikey') or
    Key.EndsWith('api_key') or Key.EndsWith('api-key');
  if Result then Exit;

  // AddSecretKey may change the list from another thread
  FLock.Enter;
  try
    for Custom in FSecretKeys do
      if Custom = Key then
        Exit(True);
  finally
    FLock.Leave;
  end;
end;

class function TDFPIISanitizer.ScrubText(const AInput: string): string;
var
  Rule: TDFScrubRule;
begin
  if AInput.IsEmpty then
    Exit('');

  Result := AInput;
  // A TRegEx keeps the subject of the current match in its instance, so concurrent
  // calls on the shared expressions would overwrite each other.
  FLock.Enter;
  try
    try
      // Secrets first, so that a value such as password=a@b.de is redacted as a secret
      Result := FSecretValueRegex.Replace(Result, '$1$2' + Redacted);
      Result := FBearerRegex.Replace(Result, '$1' + Redacted);
      for Rule in FCustomRules do
        Result := Rule.Regex.Replace(Result, Rule.Replacement);
      Result := FEmailRegex.Replace(Result, '[EMAIL_REDACTED]');
      Result := FIPv4Regex.Replace(Result, '[IP_REDACTED]');
      Result := FWinUserPathRegex.Replace(Result, '$1[USER_REDACTED]');
      Result := FUnixUserPathRegex.Replace(Result, '$1[USER_REDACTED]');
      if FHasUserNameRegex then
        Result := FUserNameRegex.Replace(Result, '[USER_REDACTED]');
      if FHasComputerNameRegex then
        Result := FComputerNameRegex.Replace(Result, '[HOST_REDACTED]');
    except
      // Fail closed: text that could not be checked must not leave the application
      Result := Redacted;
    end;
  finally
    FLock.Leave;
  end;
end;

class procedure TDFPIISanitizer.ScrubEvent(var AEvent: TDFTraceEvent);

  procedure ScrubPair(var APair: TDFKeyValuePair);
  var
    Scrubbed: string;
  begin
    if IsSecretKey(APair.Key) then
      Scrubbed := Redacted
    else
      Scrubbed := ScrubText(APair.Value);

    // Numbers and booleans are checked too, so that custom rules also catch numbers.
    // A redacted value is no longer a number and has to be written as text.
    if Scrubbed <> APair.Value then
    begin
      APair.Value := Scrubbed;
      APair.Kind := TDFValueKind.Text;
    end;
  end;

var
  I: Integer;
begin
  try
    AEvent.Message := ScrubText(AEvent.Message);
    AEvent.ExceptionMessage := ScrubText(AEvent.ExceptionMessage);
    AEvent.StackTrace := ScrubText(AEvent.StackTrace);

    for I := 0 to High(AEvent.Breadcrumbs) do
    begin
      AEvent.Breadcrumbs[I].Message := ScrubText(AEvent.Breadcrumbs[I].Message);
      AEvent.Breadcrumbs[I].Category := ScrubText(AEvent.Breadcrumbs[I].Category);
    end;

    for I := 0 to High(AEvent.Tags) do
      ScrubPair(AEvent.Tags[I]);

    for I := 0 to High(AEvent.Extra) do
      ScrubPair(AEvent.Extra[I]);
  except
    // Fail closed: keep only what cannot contain personal data
    AEvent.Message := Redacted;
    AEvent.ExceptionMessage := Redacted;
    AEvent.StackTrace := '';
    AEvent.Breadcrumbs := nil;
    AEvent.Tags := nil;
    AEvent.Extra := nil;
  end;
end;

end.
