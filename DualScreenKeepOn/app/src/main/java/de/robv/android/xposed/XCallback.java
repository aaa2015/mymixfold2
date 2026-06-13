package de.robv.android.xposed;

/**
 * Xposed 回调基类 - 存根
 */
public abstract class XCallback {
    public static class Param {
        public final Object[] args;
        
        public Param() {
            args = null;
        }
        
        public Param(Object[] args) {
            this.args = args;
        }
    }
}
