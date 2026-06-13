package de.robv.android.xposed.callbacks;

import de.robv.android.xposed.XCallback;

/**
 * XC_LoadPackage - 存根
 */
public class XC_LoadPackage extends XCallback {

    public static class LoadPackageParam extends Param {
        public String packageName;
        public String processName;
        public ClassLoader classLoader;
        public boolean isFirstApplication;
        
        public LoadPackageParam() {
            super();
        }
        
        public LoadPackageParam(Object[] args) {
            super(args);
        }
    }
}
