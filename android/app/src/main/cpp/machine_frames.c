/* JNI binding of the Machine frame codec (`src/machine_frame.c`) for `MachineFrames.kt`. */
#include <jni.h>
#include <stdlib.h>
#include "machine_frame.h"

#define METHOD(name) Java_io_github_dcostap_anvil_MachineFrames_##name

JNIEXPORT jbyteArray JNICALL METHOD(header)(JNIEnv *env, jclass cls, jint type, jint id, jint json_length,
    jint bytes_length) {
  (void)cls;
  AnvilMachineFrameHeader header = { (uint8_t)type, (uint32_t)id, (uint32_t)json_length, (uint32_t)bytes_length };
  uint8_t out[ANVIL_MACHINE_FRAME_HEADER];
  anvil_machine_frame_write_header(out, &header);
  jbyteArray array = (*env)->NewByteArray(env, ANVIL_MACHINE_FRAME_HEADER);
  if (array) (*env)->SetByteArrayRegion(env, array, 0, ANVIL_MACHINE_FRAME_HEADER, (const jbyte *)out);
  return array;
}

JNIEXPORT jlong JNICALL METHOD(newDecoder)(JNIEnv *env, jclass cls, jint max_json, jint max_bytes) {
  (void)env; (void)cls;
  AnvilMachineDecoder *decoder = malloc(sizeof(*decoder));
  if (decoder) anvil_machine_decoder_init(decoder, (uint32_t)max_json, (uint32_t)max_bytes);
  return (jlong)(intptr_t)decoder;
}

JNIEXPORT void JNICALL METHOD(freeDecoder)(JNIEnv *env, jclass cls, jlong handle) {
  (void)env; (void)cls;
  AnvilMachineDecoder *decoder = (AnvilMachineDecoder *)(intptr_t)handle;
  if (!decoder) return;
  anvil_machine_decoder_free(decoder);
  free(decoder);
}

JNIEXPORT jboolean JNICALL METHOD(feed)(JNIEnv *env, jclass cls, jlong handle, jbyteArray data, jint length) {
  (void)cls;
  AnvilMachineDecoder *decoder = (AnvilMachineDecoder *)(intptr_t)handle;
  jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
  if (!bytes) return JNI_FALSE;
  bool ok = anvil_machine_decoder_feed(decoder, bytes, (size_t)length);
  (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
  return ok ? JNI_TRUE : JNI_FALSE;
}

static jbyteArray copy_bytes(JNIEnv *env, const uint8_t *bytes, uint32_t length) {
  jbyteArray array = (*env)->NewByteArray(env, (jsize)length);
  if (array && length) (*env)->SetByteArrayRegion(env, array, 0, (jsize)length, (const jbyte *)bytes);
  return array;
}

/* Returns the next whole frame as a `MachineFrames.Frame`, or null when the decoder needs more data. An invalid
   header throws an IOException: the connection must close. */
JNIEXPORT jobject JNICALL METHOD(next)(JNIEnv *env, jclass cls, jlong handle) {
  (void)cls;
  AnvilMachineDecoder *decoder = (AnvilMachineDecoder *)(intptr_t)handle;
  AnvilMachineFrameHeader header;
  const uint8_t *json, *bytes;
  int result = anvil_machine_decoder_next(decoder, &header, &json, &bytes);
  if (result == 0) return NULL;
  if (result < 0) {
    jclass error = (*env)->FindClass(env, "java/io/IOException");
    if (error) (*env)->ThrowNew(env, error, "The Machine sent a frame that is not valid");
    return NULL;
  }
  jclass frame = (*env)->FindClass(env, "io/github/dcostap/anvil/MachineFrames$Frame");
  if (!frame) return NULL;
  jmethodID make = (*env)->GetMethodID(env, frame, "<init>", "(II[B[B)V");
  jbyteArray json_array = copy_bytes(env, json, header.json_length);
  jbyteArray bytes_array = json_array ? copy_bytes(env, bytes, header.bytes_length) : NULL;
  if (!make || !bytes_array) return NULL;
  return (*env)->NewObject(env, frame, make, (jint)header.type, (jint)header.id, json_array, bytes_array);
}
