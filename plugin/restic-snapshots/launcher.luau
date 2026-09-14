--!nonstrict
-- Launcher provider entry (prefix /snap). PLACEHOLDER: an entry pointing at a missing file fails
-- `noctalia plugins lint`, so this keeps the manifest honest until the launcher workstream -- which
-- owns this file -- replaces it with the real provider.
function onQuery(text)
  launcher.setResults(text or "", {})
end
