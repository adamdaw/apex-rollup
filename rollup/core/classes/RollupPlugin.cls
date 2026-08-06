public without sharing class RollupPlugin {
  @TestVisible
  private static List<RollupPlugin__mdt> pluginMocks = new List<RollupPlugin__mdt>();
  @TestVisible
  private static RollupPluginParameter__mdt parameterMock;
  // Mirrors Rollup.onlyUseMockMetadata: lets a test assert "no plugin is registered" without the
  // org's real records deciding the outcome. A test that leaves this false and registers no mock is
  // asserting against whatever the host org happens to have deployed — which passes in a repo with
  // no records and then fails in the org that adds one.
  @TestVisible
  private static Boolean onlyUseMockPlugins = false;

  public RollupPlugin__mdt getInstance(String developerNameOrId) {
    for (RollupPlugin__mdt plugin : pluginMocks) {
      if (plugin.DeveloperName == developerNameOrId) {
        return plugin;
      }
    }
    return onlyUseMockPlugins ? null : RollupPlugin__mdt.getInstance(developerNameOrId);
  }

  public List<RollupPlugin__mdt> getInstances() {
    List<RollupPlugin__mdt> plugins = new List<RollupPlugin__mdt>();
    if (onlyUseMockPlugins == false) {
      plugins.addAll(RollupPlugin__mdt.getAll().values());
    }
    plugins.addAll(pluginMocks);
    return plugins;
  }

  public RollupPluginParameter__mdt getParameterInstance(String developerNameOrId) {
    return parameterMock ?? RollupPluginParameter__mdt.getInstance(developerNameOrId);
  }

  public List<RollupPluginParameter__mdt> getMatchingParameters(Id pluginId) {
    List<RollupPluginParameter__mdt> pluginParameters = onlyUseMockPlugins
      ? new List<RollupPluginParameter__mdt>()
      : new List<RollupPluginParameter__mdt>(RollupPluginParameter__mdt.getAll().values());
    if (parameterMock != null) {
      pluginParameters.add(parameterMock);
    }
    for (Integer index = pluginParameters.size() - 1; index >= 0; index--) {
      RollupPluginParameter__mdt pluginParameter = pluginParameters[index];
      if (pluginParameter.RollupPlugin__c != null && pluginParameter.RollupPlugin__c != pluginId) {
        pluginParameters.remove(index);
      }
    }
    return pluginParameters;
  }
}
