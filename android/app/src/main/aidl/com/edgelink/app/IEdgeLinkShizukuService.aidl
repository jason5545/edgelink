package com.edgelink.app;

interface IEdgeLinkShizukuService {
    void destroy() = 16777114;

    String runCommand(in String[] command) = 1;

    void setMiConnectPermissionSwitch(boolean enabled) = 6;

    boolean injectScroll(int x, int y, int wheelDy) = 7;
}
