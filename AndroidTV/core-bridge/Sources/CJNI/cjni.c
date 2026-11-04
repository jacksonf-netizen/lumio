// JNI entry points and callbacks for com.jackson.lumio.core.LumioCore. See cjni.h.

#include "cjni.h"

#include <android/log.h>
#include <android/looper.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TAG "Lumio.bridge"

static JavaVM *vm;
static jobject listener;            // global reference to the Kotlin CoreListener
static jmethodID on_event, save_secret, load_secret, delete_secret;
static pthread_key_t detach_key;

// MARK: Threads

// Swift runs work on threads Java doesn't know. Each attaches once and detaches when it ends
// (Android aborts the app if an attached thread exits without detaching).
static void detach_thread(void *unused) {
    (void)unused;
    (*vm)->DetachCurrentThread(vm);
}

static JNIEnv *current_env(void) {
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK) return env;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
    pthread_setspecific(detach_key, env);
    return env;
}

// MARK: Byte arrays (UTF-8)

static jbyteArray bytes_from(JNIEnv *env, const char *text) {
    if (text == NULL) return NULL;
    jsize length = (jsize)strlen(text);
    jbyteArray array = (*env)->NewByteArray(env, length);
    if (array != NULL) (*env)->SetByteArrayRegion(env, array, 0, length, (const jbyte *)text);
    return array;
}

/// A malloc'd, NUL-terminated copy of a Java byte array, or NULL.
static char *text_from(JNIEnv *env, jbyteArray array) {
    if (array == NULL) return NULL;
    jsize length = (*env)->GetArrayLength(env, array);
    char *text = malloc((size_t)length + 1);
    if (text == NULL) return NULL;
    (*env)->GetByteArrayRegion(env, array, 0, length, (jbyte *)text);
    text[length] = '\0';
    return text;
}

static bool clear_exception(JNIEnv *env) {
    if (!(*env)->ExceptionCheck(env)) return false;
    (*env)->ExceptionClear(env);
    return true;
}

// MARK: The main queue

// Swift's main queue (and so the main actor) runs only when something drains it. Hooking its
// wake-up file descriptor into the UI thread's looper drains it there, as on the Mac's main thread.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *message);

static int drain_main_queue(int fd, int events, void *data) {
    (void)events;
    (void)data;
    // One read takes the descriptor's whole count (it's an eventfd); a second would block the UI
    // thread until the next wake-up, because the descriptor isn't non-blocking.
    uint64_t value;
    (void)read(fd, &value, sizeof value);
    _dispatch_main_queue_callback_4CF(NULL);
    return 1;  // keep the callback
}

static void attach_main_queue(void) {
    ALooper *looper = ALooper_forThread();
    if (looper == NULL) {
        __android_log_write(ANDROID_LOG_ERROR, TAG, "nativeStart wasn't called on a looper thread");
        return;
    }
    ALooper_addFd(looper, _dispatch_get_main_queue_handle_4CF(), ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT,
                  drain_main_queue, NULL);
}

// MARK: Called by Kotlin

/// LumioCore.nativeStart(databasePath: ByteArray, cacheDir: ByteArray, listener: CoreListener): ByteArray?
/// Call once, on the UI thread. Returns null, or an error message.
JNIEXPORT jbyteArray JNICALL Java_com_jackson_lumio_core_LumioCore_nativeStart(
    JNIEnv *env, jclass type, jbyteArray database_path, jbyteArray cache_dir, jobject callbacks) {
    (void)type;
    if (listener != NULL) return NULL;  // already started
    (*env)->GetJavaVM(env, &vm);
    pthread_key_create(&detach_key, detach_thread);
    listener = (*env)->NewGlobalRef(env, callbacks);
    jclass listener_class = (*env)->GetObjectClass(env, callbacks);
    on_event = (*env)->GetMethodID(env, listener_class, "onEvent", "([B)V");
    save_secret = (*env)->GetMethodID(env, listener_class, "saveSecret", "([B[B)Z");
    load_secret = (*env)->GetMethodID(env, listener_class, "loadSecret", "([B)[B");
    delete_secret = (*env)->GetMethodID(env, listener_class, "deleteSecret", "([B)Z");
    if (clear_exception(env) || !on_event || !save_secret || !load_secret || !delete_secret) {
        return bytes_from(env, "The app's core listener is missing a method.");
    }

    // Android apps get no TMPDIR, so Foundation's temporary folder would be /data/local/tmp, which
    // apps can't write (downloads would fail). Use the app's cache folder.
    char *cache = text_from(env, cache_dir);
    if (cache != NULL) setenv("TMPDIR", cache, 1);
    free(cache);

    attach_main_queue();
    char *path = text_from(env, database_path);
    char *error = lumio_swift_start(path);
    free(path);
    jbyteArray result = bytes_from(env, error);
    free(error);
    return result;
}

/// LumioCore.nativeCall(request: ByteArray): ByteArray. Blocks until the reply; call it off the UI
/// thread.
JNIEXPORT jbyteArray JNICALL Java_com_jackson_lumio_core_LumioCore_nativeCall(JNIEnv *env, jclass type, jbyteArray request) {
    (void)type;
    char *text = text_from(env, request);
    char *reply = lumio_swift_call(text != NULL ? text : "");
    free(text);
    jbyteArray result = bytes_from(env, reply);
    free(reply);
    return result;
}

// MARK: Called by Swift

void lumio_emit_event(const char *json) {
    if (listener == NULL) return;
    JNIEnv *env = current_env();
    if (env == NULL) return;
    jbyteArray bytes = bytes_from(env, json);
    (*env)->CallVoidMethod(env, listener, on_event, bytes);
    clear_exception(env);
    (*env)->DeleteLocalRef(env, bytes);
}

bool lumio_secret_save(const char *provider_id, const char *value) {
    JNIEnv *env = listener != NULL ? current_env() : NULL;
    if (env == NULL) return false;
    jbyteArray id = bytes_from(env, provider_id), bytes = bytes_from(env, value);
    jboolean saved = (*env)->CallBooleanMethod(env, listener, save_secret, id, bytes);
    bool failed = clear_exception(env);
    (*env)->DeleteLocalRef(env, id);
    (*env)->DeleteLocalRef(env, bytes);
    return saved && !failed;
}

char *lumio_secret_load(const char *provider_id) {
    JNIEnv *env = listener != NULL ? current_env() : NULL;
    if (env == NULL) return NULL;
    jbyteArray id = bytes_from(env, provider_id);
    jbyteArray value = (jbyteArray)(*env)->CallObjectMethod(env, listener, load_secret, id);
    char *text = clear_exception(env) ? NULL : text_from(env, value);
    (*env)->DeleteLocalRef(env, id);
    if (value != NULL) (*env)->DeleteLocalRef(env, value);
    return text;
}

bool lumio_secret_delete(const char *provider_id) {
    JNIEnv *env = listener != NULL ? current_env() : NULL;
    if (env == NULL) return false;
    jbyteArray id = bytes_from(env, provider_id);
    jboolean deleted = (*env)->CallBooleanMethod(env, listener, delete_secret, id);
    bool failed = clear_exception(env);
    (*env)->DeleteLocalRef(env, id);
    return deleted && !failed;
}
