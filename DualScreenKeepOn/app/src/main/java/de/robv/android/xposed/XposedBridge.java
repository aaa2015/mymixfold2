package de.robv.android.xposed;

import java.lang.reflect.Member;

/**
 * XposedBridge - 存根
 * 实际实现在 LSPosed 框架中
 */
public class XposedBridge {
    
    public static void log(String text) {
        android.util.Log.i("Xposed", text);
    }
    
    public static void log(Throwable t) {
        android.util.Log.e("Xposed", "Error", t);
    }
    
    public static XC_MethodHook.Unhook hookMethod(Member hookMethod, XC_MethodHook callback) {
        return new XC_MethodHook.Unhook(callback);
    }
    
    public static XC_MethodHook.Unhook hookAllMethods(Class<?> hookClass, String methodName, XC_MethodHook callback) {
        return new XC_MethodHook.Unhook(callback);
    }
    
    public static XC_MethodHook.Unhook hookAllConstructors(Class<?> hookClass, XC_MethodHook callback) {
        return new XC_MethodHook.Unhook(callback);
    }
}
