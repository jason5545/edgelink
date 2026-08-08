package com.edgelink.app;

interface IEdgeLinkShizukuService {
    void destroy() = 16777114;

    String runCommand(in String[] command) = 1;

    void startCallUplinkInjector() = 4;

    void stopCallUplinkInjector() = 5;

    void setMiConnectPermissionSwitch(boolean enabled) = 6;
}
