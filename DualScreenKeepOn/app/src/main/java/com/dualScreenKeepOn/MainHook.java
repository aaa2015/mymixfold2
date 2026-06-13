package com.dualscreen.keepon;

import android.util.Log;
import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * LSPosed 模块 - 小米 Mix Fold 2 双屏同时显示
 *
 * 核心策略:
 * 1. Hook DeviceStateManagerService — 拦截状态切换，展开时强制保持 state 5
 * 2. Hook DisplayManagerService.setDisplayState() — 阻止关闭任一屏幕
 * 3. Hook LocalDisplayAdapter — 拦截底层屏幕电源状态变化
 *
 * Display 映射:
 *   displayId=0, port=131 → 内屏 (1080x2520)
 *   displayId=1, port=130 → 外屏 (1914x2160)
 *
 * Device States:
 *   0=CLOSED, 2=HALF_OPENED, 3=OPENED, 4=OPENED_REVERSE
 *   5=OPENED_PRESENTATION (目标: 双屏亮)
 *   6=OPENED_REVERSE_PRESENTATION
 */
public class MainHook implements IXposedHookLoadPackage {

    private static final String TAG = "DualScreenKeepOn";
    private static final String PACKAGE_SYSTEM = "android";

    // Display IDs
    private static final int OUTER_DISPLAY_ID = 1;
    private static final int INNER_DISPLAY_ID = 0;

    // Display state 常量
    private static final int DISPLAY_STATE_OFF = 1;
    private static final int DISPLAY_STATE_ON = 2;

    // Device state 常量
    private static final int STATE_CLOSED = 0;
    private static final int STATE_HALF_OPENED = 2;
    private static final int STATE_OPENED = 3;
    private static final int STATE_OPENED_REVERSE = 4;
    private static final int STATE_OPENED_PRESENTATION = 5;
    private static final int STATE_OPENED_REVERSE_PRESENTATION = 6;

    // 当前物理折叠状态 (来自 DeviceStateProvider)
    private volatile int mPhysicalState = -1;
    // 是否处于展开状态
    private volatile boolean mIsUnfolded = false;
    // 模块开关
    private volatile boolean mModuleEnabled = true;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (!lpparam.packageName.equals(PACKAGE_SYSTEM)) {
            return;
        }

        Log.i(TAG, "模块加载到系统框架");
        XposedBridge.log(TAG + ": 模块加载到系统框架");

        try {
            // 策略1: Hook DeviceStateManagerService — 监听物理状态变化
            hookDeviceStateManager(lpparam);

            // 策略2: Hook DisplayManagerService — 阻止关闭屏幕
            hookDisplayPowerState(lpparam);

            // 策略3: Hook DisplayPowerController — 拦截屏幕电源策略
            hookDisplayPowerController(lpparam);

        } catch (Throwable t) {
            Log.e(TAG, "Hook 初始化失败", t);
            XposedBridge.log(TAG + ": Hook 初始化失败 - " + t.getMessage());
        }
    }

    // ====================================================================
    // 策略1: Hook DeviceStateManagerService
    // 监听折叠状态变化，在展开时自动注入 state 5
    // ====================================================================
    private void hookDeviceStateManager(XC_LoadPackage.LoadPackageParam lpparam) {
        // Hook 1a: DeviceStateManagerService.commitDeviceState
        // 这是 device state 最终生效的地方
        try {
            Class<?> dsmsClass = XposedHelpers.findClass(
                "com.android.server.devicestate.DeviceStateManagerService",
                lpparam.classLoader);

            // 方法: commitDeviceState(DeviceState, why)
            // 当系统提交一个新的 device state 时调用
            XposedBridge.hookAllMethods(dsmsClass, "commitDeviceState",
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                        if (!mModuleEnabled) return;

                        Object deviceState = param.args[0];
                        if (deviceState == null) return;

                        int identifier = XposedHelpers.getIntField(deviceState, "mIdentifier");

                        Log.d(TAG, "commitDeviceState: identifier=" + identifier);

                        // 如果系统要切换到 OPENED (3) 但物理状态是展开的
                        // 我们替换为 OPENED_PRESENTATION (5)
                        if (identifier == STATE_OPENED && mIsUnfolded) {
                            try {
                                // 寻找 state 5 的 DeviceState 对象
                                Object state5 = findDeviceState(param.thisObject, STATE_OPENED_PRESENTATION);
                                if (state5 != null) {
                                    param.args[0] = state5;
                                    Log.i(TAG, "commitDeviceState: OPENED(3) -> OPENED_PRESENTATION(5) 已替换");
                                    XposedBridge.log(TAG + ": state 3->5 替换成功");
                                }
                            } catch (Exception e) {
                                Log.w(TAG, "替换 DeviceState 失败", e);
                            }
                        }

                        // 同样处理 OPENED_REVERSE
                        if (identifier == STATE_OPENED_REVERSE && mIsUnfolded) {
                            try {
                                Object state6 = findDeviceState(param.thisObject, STATE_OPENED_REVERSE_PRESENTATION);
                                if (state6 != null) {
                                    param.args[0] = state6;
                                    Log.i(TAG, "commitDeviceState: OPENED_REVERSE(4) -> OPENED_REVERSE_PRESENTATION(6) 已替换");
                                }
                            } catch (Exception e) {
                                Log.w(TAG, "替换 DeviceState 失败", e);
                            }
                        }
                    }
                });

            Log.i(TAG, "DeviceStateManagerService.commitDeviceState Hook 成功");
            XposedBridge.log(TAG + ": DeviceStateManagerService Hook 成功");
        } catch (Exception e) {
            Log.w(TAG, "DeviceStateManagerService Hook 失败: " + e.getMessage());
            XposedBridge.log(TAG + ": DeviceStateManagerService Hook 失败: " + e.getMessage());
        }

        // Hook 1b: DeviceStateProviderImpl — 监听物理传感器状态
        hookDeviceStateProvider(lpparam);
    }

    /**
     * 从 DeviceStateManagerService 中查找特定 identifier 的 DeviceState 对象
     */
    private Object findDeviceState(Object dsmService, int targetIdentifier) {
        try {
            // 尝试获取 mDeviceStates 列表
            Object deviceStates = null;
            String[] fieldNames = {"mDeviceStates", "mDeviceStatesMap", "mSupportedStates"};

            for (String fieldName : fieldNames) {
                try {
                    deviceStates = XposedHelpers.getObjectField(dsmService, fieldName);
                    if (deviceStates != null) break;
                } catch (NoSuchFieldError ignored) {}
            }

            if (deviceStates == null) {
                Log.w(TAG, "找不到 device states 字段");
                return null;
            }

            // 根据类型遍历查找
            if (deviceStates instanceof java.util.Map) {
                java.util.Map<?, ?> map = (java.util.Map<?, ?>) deviceStates;
                for (Object value : map.values()) {
                    int id = XposedHelpers.getIntField(value, "mIdentifier");
                    if (id == targetIdentifier) return value;
                }
            } else if (deviceStates instanceof java.util.List) {
                java.util.List<?> list = (java.util.List<?>) deviceStates;
                for (Object item : list) {
                    int id = XposedHelpers.getIntField(item, "mIdentifier");
                    if (id == targetIdentifier) return item;
                }
            } else if (deviceStates.getClass().isArray()) {
                Object[] arr = (Object[]) deviceStates;
                for (Object item : arr) {
                    int id = XposedHelpers.getIntField(item, "mIdentifier");
                    if (id == targetIdentifier) return item;
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "findDeviceState 失败", e);
        }
        return null;
    }

    /**
     * Hook DeviceStateProviderImpl — 追踪物理折叠状态
     */
    private void hookDeviceStateProvider(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            Class<?> providerClass = XposedHelpers.findClass(
                "com.android.server.devicestate.DeviceStateProviderImpl",
                lpparam.classLoader);

            // Hook notifyDeviceStateChangedIfNeeded 或 onSensorEvent
            // 来追踪物理折叠状态
            XposedBridge.hookAllMethods(providerClass, "notifyDeviceStateChangedIfNeeded",
                new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                        try {
                            Object provider = param.thisObject;
                            int lastState = XposedHelpers.getIntField(provider, "mLastReportedState");
                            updateFoldState(lastState);
                        } catch (NoSuchFieldError e) {
                            // 字段名可能不同，尝试其他
                        }
                    }
                });

            Log.i(TAG, "DeviceStateProviderImpl Hook 成功");
        } catch (Exception e) {
            Log.w(TAG, "DeviceStateProviderImpl Hook 失败: " + e.getMessage());

            // 备用: 尝试 Hook DeviceStateManagerService 的 base state 更新
            try {
                Class<?> dsmsClass = XposedHelpers.findClass(
                    "com.android.server.devicestate.DeviceStateManagerService",
                    lpparam.classLoader);

                // 在 Android 14/15 中，setBaseState 是更新物理状态的方法
                String[] baseStateMethodNames = {
                    "setBaseState", "onBaseStateChanged", "updateBaseState"
                };
                for (String methodName : baseStateMethodNames) {
                    try {
                        XposedBridge.hookAllMethods(dsmsClass, methodName,
                            new XC_MethodHook() {
                                @Override
                                protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                                    if (param.args.length > 0) {
                                        Object stateArg = param.args[0];
                                        int identifier;
                                        if (stateArg instanceof Integer) {
                                            identifier = (int) stateArg;
                                        } else {
                                            identifier = XposedHelpers.getIntField(stateArg, "mIdentifier");
                                        }
                                        updateFoldState(identifier);
                                    }
                                }
                            });
                        Log.i(TAG, "DeviceStateManagerService." + methodName + " Hook 成功 (备用)");
                        break;
                    } catch (NoSuchMethodError ignored) {}
                }
            } catch (Exception ex) {
                Log.e(TAG, "所有物理状态追踪 Hook 失败", ex);
            }
        }
    }

    /**
     * 更新折叠状态
     */
    private void updateFoldState(int physicalState) {
        if (physicalState == mPhysicalState) return;

        boolean wasUnfolded = mIsUnfolded;
        mPhysicalState = physicalState;
        mIsUnfolded = (physicalState == STATE_OPENED ||
                       physicalState == STATE_OPENED_REVERSE ||
                       physicalState == STATE_HALF_OPENED ||
                       physicalState == STATE_OPENED_PRESENTATION ||
                       physicalState == STATE_OPENED_REVERSE_PRESENTATION);

        if (wasUnfolded != mIsUnfolded) {
            Log.i(TAG, "折叠状态变化: " + (mIsUnfolded ? "展开" : "折叠") +
                  " (physical=" + physicalState + ")");
            XposedBridge.log(TAG + ": 折叠状态 -> " +
                (mIsUnfolded ? "展开" : "折叠") + " (state=" + physicalState + ")");
        }
    }

    // ====================================================================
    // 策略2: Hook DisplayManagerService — 阻止屏幕关闭
    // ====================================================================
    private void hookDisplayPowerState(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            // 在 Android 14/15 中，屏幕电源状态由 LogicalDisplay 或 DisplayDevice 管理
            Class<?> ldaClass = XposedHelpers.findClass(
                "com.android.server.display.LocalDisplayAdapter$LocalDisplayDevice",
                lpparam.classLoader);

            // Hook requestDisplayStateLocked — 请求显示状态变化
            XposedBridge.hookAllMethods(ldaClass, "requestDisplayStateLocked",
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                        if (!mModuleEnabled || !mIsUnfolded) return;

                        int state = (int) param.args[0];
                        // float brightness = (float) param.args[1];

                        if (state == DISPLAY_STATE_OFF) {
                            // 获取当前 display device 的信息
                            Object displayDevice = param.thisObject;
                            try {
                                Object displayDeviceInfo = XposedHelpers.callMethod(displayDevice, "getDisplayDeviceInfoLocked");
                                String uniqueId = (String) XposedHelpers.getObjectField(displayDeviceInfo, "uniqueId");

                                Log.i(TAG, "拦截屏幕关闭: uniqueId=" + uniqueId + ", state=OFF -> 已阻止");
                                param.args[0] = DISPLAY_STATE_ON;  // 改为 ON
                            } catch (Exception e) {
                                // 如果无法获取 display info，也阻止关闭
                                Log.i(TAG, "拦截屏幕关闭: state=OFF -> ON (无法获取 displayId)");
                                param.args[0] = DISPLAY_STATE_ON;
                            }
                        }
                    }
                });

            Log.i(TAG, "LocalDisplayDevice.requestDisplayStateLocked Hook 成功");
            XposedBridge.log(TAG + ": LocalDisplayDevice Hook 成功");
        } catch (Exception e) {
            Log.w(TAG, "LocalDisplayDevice Hook 失败: " + e.getMessage());
            // 备用: Hook DisplayManagerService.setDisplayState
            hookDisplayManagerServiceFallback(lpparam);
        }
    }

    /**
     * 备用方案: Hook DisplayManagerService.setDisplayState
     */
    private void hookDisplayManagerServiceFallback(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            Class<?> dmsClass = XposedHelpers.findClass(
                "com.android.server.display.DisplayManagerService",
                lpparam.classLoader);

            XposedBridge.hookAllMethods(dmsClass, "setDisplayState", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                    if (!mModuleEnabled || !mIsUnfolded) return;

                    if (param.args.length >= 2) {
                        int displayId = (int) param.args[0];
                        int state = (int) param.args[1];

                        if (state == DISPLAY_STATE_OFF) {
                            Log.i(TAG, "阻止屏幕关闭: displayId=" + displayId +
                                  ", state=OFF -> 已拦截");
                            param.setResult(null);
                        }
                    }
                }
            });

            Log.i(TAG, "DisplayManagerService.setDisplayState Hook 成功 (备用)");
        } catch (Exception e) {
            Log.e(TAG, "DisplayManagerService Hook 也失败了", e);
        }
    }

    // ====================================================================
    // 策略3: Hook DisplayPowerController
    // ====================================================================
    private void hookDisplayPowerController(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            Class<?> dpcClass = XposedHelpers.findClass(
                "com.android.server.display.DisplayPowerController",
                lpparam.classLoader);

            // Hook requestPowerState — 阻止关闭请求
            XposedBridge.hookAllMethods(dpcClass, "requestPowerState",
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                        if (!mModuleEnabled || !mIsUnfolded) return;

                        // 获取 DisplayPowerRequest 参数
                        Object request = param.args[0];
                        if (request == null) return;

                        try {
                            int policy = XposedHelpers.getIntField(request, "policy");
                            // policy 0 = OFF, 1 = DOZE, 2 = DIM, 3 = BRIGHT
                            if (policy == 0) {
                                // 获取对应的 displayId
                                Object controller = param.thisObject;
                                int displayId = -1;
                                try {
                                    displayId = XposedHelpers.getIntField(controller, "mDisplayId");
                                } catch (NoSuchFieldError ignored) {}

                                Log.i(TAG, "拦截 DisplayPowerController.requestPowerState: " +
                                      "displayId=" + displayId + ", policy=OFF -> BRIGHT");
                                XposedHelpers.setIntField(request, "policy", 3); // BRIGHT
                            }
                        } catch (NoSuchFieldError e) {
                            // 字段不存在
                        }
                    }
                });

            Log.i(TAG, "DisplayPowerController.requestPowerState Hook 成功");
        } catch (Exception e) {
            Log.w(TAG, "DisplayPowerController Hook 失败: " + e.getMessage());
        }
    }
}
