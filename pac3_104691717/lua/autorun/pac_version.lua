if SERVER then
  SetGlobalString("pac_version", "bdfea7a6a5b0eb034dc661ebffa2fe10698bc07b")
end
function _G.PAC_VERSION()
  return GetGlobalString("pac_version")
end
concommand.Add("pac_version", function()
  print(PAC_VERSION())
end)
