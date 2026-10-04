{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit lazaruscodingagent;

{$warn 5023 off : no warning about unused units}
interface

uses
  uAgentTypes, uAgentConfig, uAgentHistory, uAgentCore, uAgentThread, uLLMClient,
  uToolBase, uToolFileOps, uFrmSettings, uFrmModelPicker, uFrmChat, uAgentPlugin, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('uAgentPlugin', @uAgentPlugin.Register);
end;

initialization
  RegisterPackage('lazaruscodingagent', @Register);
end.
