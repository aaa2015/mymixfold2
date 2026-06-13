package com.dualscreen.keepon;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * Xposed 入口点 - 供 LSPosed 识别
 * LSPosed 会自动查找实现了 IXposedHookLoadPackage 的类
 */
public class XposedInit implements IXposedHookLoadPackage {

    private final MainHook mainHook = new MainHook();

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        mainHook.handleLoadPackage(lpparam);
    }
}
