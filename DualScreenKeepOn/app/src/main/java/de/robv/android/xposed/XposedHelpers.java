package de.robv.android.xposed;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * XposedHelpers - 存根
 * 实际实现在 LSPosed 框架中
 */
public class XposedHelpers {

    public static Class<?> findClass(String className, ClassLoader classLoader) throws ClassNotFoundError {
        try {
            return Class.forName(className, false, classLoader);
        } catch (ClassNotFoundException e) {
            throw new ClassNotFoundError(e);
        }
    }

    public static Class<?> findClassIfExists(String className, ClassLoader classLoader) {
        try {
            return findClass(className, classLoader);
        } catch (ClassNotFoundError e) {
            return null;
        }
    }

    public static class ClassNotFoundError extends Error {
        private static final long serialVersionUID = 1L;
        
        public ClassNotFoundError(Throwable cause) {
            super(cause);
        }
        
        public ClassNotFoundError(String detailMessage, Throwable cause) {
            super(detailMessage, cause);
        }
    }

    public static Object callMethod(Object obj, String methodName, Object... args) throws Exception {
        Class<?>[] paramTypes = new Class<?>[args.length];
        for (int i = 0; i < args.length; i++) {
            paramTypes[i] = args[i].getClass();
        }
        Method method = findMethodBestMatch(obj.getClass(), methodName, paramTypes);
        if (method == null) {
            throw new NoSuchMethodError(methodName);
        }
        return method.invoke(obj, args);
    }

    public static Object callStaticMethod(Class<?> clazz, String methodName, Object... args) throws Exception {
        Class<?>[] paramTypes = new Class<?>[args.length];
        for (int i = 0; i < args.length; i++) {
            paramTypes[i] = args[i].getClass();
        }
        Method method = findMethodBestMatch(clazz, methodName, paramTypes);
        if (method == null) {
            throw new NoSuchMethodError(methodName);
        }
        return method.invoke(null, args);
    }

    public static Object getObjectField(Object obj, String fieldName) throws Exception {
        Field field = findField(obj.getClass(), fieldName);
        if (field == null) {
            throw new NoSuchFieldError(fieldName);
        }
        return field.get(obj);
    }

    public static int getIntField(Object obj, String fieldName) throws Exception {
        Field field = findField(obj.getClass(), fieldName);
        if (field == null) {
            throw new NoSuchFieldError(fieldName);
        }
        return field.getInt(obj);
    }

    public static void setIntField(Object obj, String fieldName, int value) throws Exception {
        Field field = findField(obj.getClass(), fieldName);
        if (field == null) {
            throw new NoSuchFieldError(fieldName);
        }
        field.setInt(obj, value);
    }

    public static Object getStaticObjectField(Class<?> clazz, String fieldName) throws Exception {
        Field field = findField(clazz, fieldName);
        if (field == null) {
            throw new NoSuchFieldError(fieldName);
        }
        return field.get(null);
    }

    public static void setObjectField(Object obj, String fieldName, Object value) throws Exception {
        Field field = findField(obj.getClass(), fieldName);
        if (field == null) {
            throw new NoSuchFieldError(fieldName);
        }
        field.set(obj, value);
    }

    private static Field findField(Class<?> clazz, String fieldName) {
        Class<?> current = clazz;
        while (current != null) {
            try {
                Field field = current.getDeclaredField(fieldName);
                field.setAccessible(true);
                return field;
            } catch (NoSuchFieldException e) {
                current = current.getSuperclass();
            }
        }
        return null;
    }

    private static Method findMethodBestMatch(Class<?> clazz, String methodName, Class<?>... paramTypes) {
        Class<?> current = clazz;
        while (current != null) {
            try {
                Method method = current.getDeclaredMethod(methodName, paramTypes);
                method.setAccessible(true);
                return method;
            } catch (NoSuchMethodException e) {
                current = current.getSuperclass();
            }
        }
        return null;
    }
}
