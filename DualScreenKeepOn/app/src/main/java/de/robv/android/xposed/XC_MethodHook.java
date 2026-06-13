package de.robv.android.xposed;

/**
 * XC_MethodHook - 存根
 * 实际实现在 LSPosed 框架中
 */
public class XC_MethodHook extends XCallback {
    
    public static class MethodHookParam extends Param {
        public Object thisObject;
        
        public Object getResult() {
            return null;
        }
        
        public void setResult(Object result) {
            throw new UnsupportedOperationException("Stub!");
        }
        
        public void setResultNull() {
            throw new UnsupportedOperationException("Stub!");
        }
        
        public Object getObjectExtra(String key) {
            return null;
        }
        
        public void setObjectExtra(String key, Object o) {
        }
        
        public long getResultLong() {
            return 0;
        }
        
        public void setResultLong(long result) {
        }
        
        public boolean getResultBoolean() {
            return false;
        }
        
        public void setResultBoolean(boolean result) {
        }
        
        public int getResultInt() {
            return 0;
        }
        
        public void setResultInt(int result) {
        }
        
        public float getResultFloat() {
            return 0;
        }
        
        public void setResultFloat(float result) {
        }
        
        public double getResultDouble() {
            return 0;
        }
        
        public void setResultDouble(double result) {
        }
        
        public Throwable getThrowable() {
            return null;
        }
        
        public boolean hasThrowable() {
            return false;
        }
        
        public Object getResultOrThrowable() throws Throwable {
            return null;
        }
    }
    
    public static class Unhook {
        private final XC_MethodHook callback;
        
        public Unhook(XC_MethodHook callback) {
            this.callback = callback;
        }
        
        public XC_MethodHook getCallback() {
            return callback;
        }
        
        public void unhook() {
        }
    }
    
    protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
    }
    
    protected void afterHookedMethod(MethodHookParam param) throws Throwable {
    }
}
