package com.edgelink.app;

interface IEdgeLinkShizukuService {
    void destroy() = 16777114;

    String runCommand(in String[] command) = 1;
    String acquireScreenWakeLock() = 2;
    String releaseScreenWakeLock() = 3;
}
