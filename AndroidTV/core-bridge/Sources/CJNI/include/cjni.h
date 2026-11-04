// The Android side of the bridge, in C (JNI is a C interface). The Kotlin class
// com.jackson.lumio.core.LumioCore calls the two native functions in cjni.c; they call the Swift
// functions declared at the bottom, which drive the shared core (IPTVBridge).
//
// Text crosses as UTF-8 byte arrays, not Java strings: JNI's string functions use "modified UTF-8",
// which mangles (and on some Android versions crashes on) characters outside the basic plane, such
// as the emoji many IPTV channel names carry.

#include <jni.h>
#include <stdbool.h>

// Called by Swift.

/// Sends an event (JSON) to the Kotlin listener. Safe from any thread.
void lumio_emit_event(const char *json);
/// Saved logins, kept by Kotlin in a Keystore-encrypted file. `load` returns a malloc'd string the
/// caller frees, or NULL when there is none.
bool lumio_secret_save(const char *provider_id, const char *value);
char *lumio_secret_load(const char *provider_id);
bool lumio_secret_delete(const char *provider_id);

// Implemented in Swift (Bridge.swift).

/// Opens the database and starts the core. Returns NULL on success, or a malloc'd error message.
char *lumio_swift_start(const char *database_path);
/// Runs one request (JSON) and returns the reply (JSON, malloc'd).
char *lumio_swift_call(const char *request);
