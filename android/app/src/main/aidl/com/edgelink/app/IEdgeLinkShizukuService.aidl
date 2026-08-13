package com.edgelink.app;

interface IEdgeLinkShizukuService {
    void destroy() = 16777114;

    String runCommand(in String[] command) = 1;

    void setMiConnectPermissionSwitch(boolean enabled) = 6;

    String lyraSeed(String requestJson, in byte[] dexBytes) = 7;
}
