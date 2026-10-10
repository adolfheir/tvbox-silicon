#import <Foundation/Foundation.h>
#include <signal.h>
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <os/proc.h>
#include <TargetConditionals.h>
#include "RuntimeMemoryBudget.h"

// Called from the app's plugin worker threads (several at once for searches), never the UI thread.
// Only VM startup needs a lock; each later call attaches its own thread.
static pthread_mutex_t startLock = PTHREAD_MUTEX_INITIALIZER;
static JavaVM *runtimeVM;
static jclass bootstrap;
static jmethodID requestMethod;
static BOOL failed;
static char *failure(const char *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"error": @(message)} options:0 error:NULL];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
char *TVAppleRuntimeRequest(const char *resourcePath, const char *requestJSON);

// On a memory warning, idle plugin runtimes and sources are closed and the freed heap returned.
static void watchMemoryPressure(const char *resourcePath) {
    static dispatch_source_t source;
    NSString *resources = @(resourcePath);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, queue);
    dispatch_source_set_event_handler(source, ^{
        char *result = TVAppleRuntimeRequest(resources.UTF8String, "{\"command\":\"trim\"}");
        free(result);
    });
    dispatch_resume(source);
}

char *TVAppleRuntimeRequest(const char *resourcePath, const char *requestJSON) {
    @autoreleasepool {
        if (failed) return failure("The plugin runtime failed. Restart the app to retry.");
        JNIEnv *env = NULL;
        pthread_mutex_lock(&startLock);
        if (!runtimeVM) {
            NSString *root = @(resourcePath);
            NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            NSString *log = [cache stringByAppendingPathComponent:@"embedded-jvm.log"];
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:log error:NULL];
            freopen(log.UTF8String, [attributes fileSize] > 2 * 1024 * 1024 ? "w" : "a", stderr);
            setbuf(stderr, NULL);
            fprintf(stderr, "Starting on-device Java runtime\n");
            NSString *host = [root stringByAppendingPathComponent:@"JavaHost"];
            NSString *classpath = [host stringByAppendingPathComponent:@"apple-bindings.jar"];
            classpath = [classpath stringByAppendingFormat:@":%@", [host stringByAppendingPathComponent:@"host.jar"]];
            for (NSString *file in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[host stringByAppendingPathComponent:@"lib"] error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
                if ([file.pathExtension isEqualToString:@"jar"]) classpath = [classpath stringByAppendingFormat:@":%@/lib/%@", host, file];
            }
            TVRuntimeMemoryBudget budget = TVCurrentRuntimeMemoryBudget();
            fprintf(stderr, "Java memory budget available=%lluMiB heap=%uMiB classSpace=%uMiB\n",
                    (unsigned long long)(budget.availableBytes / TV_MIB), budget.heapMB, budget.classSpaceMB);
            if (budget.availableBytes < 256 * TV_MIB) {
                pthread_mutex_unlock(&startLock);
                return failure("Not enough memory to start a Java source. Close other sources and retry.");
            }
            NSString *heap = [NSString stringWithFormat:@"-Xmx%um", budget.heapMB];
            NSString *classes = [NSString stringWithFormat:@"-XX:CompressedClassSpaceSize=%um", budget.classSpaceMB];
            // Shrink the committed heap after collections, so memory freed in Java goes back to iOS.
            NSArray<NSString *> *arguments = @[heap, classes, @"-Xms32m", @"-Xss2m", @"-XX:+UseSerialGC", @"-XX:MinHeapFreeRatio=10", @"-XX:MaxHeapFreeRatio=30", @"-XX:+DisableAttachMechanism", @"-Xrs",
                @"--add-opens=java.base/java.lang=ALL-UNNAMED", @"--add-opens=java.base/sun.net.www.protocol.jar=ALL-UNNAMED",
                @"--enable-native-access=ALL-UNNAMED",
                @"-Dorg.slf4j.simpleLogger.defaultLogLevel=error",
                [@"-Djava.home=" stringByAppendingString:[root stringByAppendingPathComponent:@"lib"]],
                [@"-Djava.class.path=" stringByAppendingString:classpath],
                [@"-Djava.io.tmpdir=" stringByAppendingString:NSTemporaryDirectory()]];
            JavaVMOption options[arguments.count];
            for (NSUInteger i=0;i<arguments.count;i++) { options[i].optionString=(char *)arguments[i].UTF8String; options[i].extraInfo=NULL; }
            JavaVMInitArgs init={.version=JNI_VERSION_1_8,.nOptions=(jint)arguments.count,.options=options,.ignoreUnrecognized=JNI_FALSE};
            jint status=JNI_CreateJavaVM(&runtimeVM,(void **)&env,&init);
            if (status != JNI_OK) { runtimeVM=NULL; failed=YES; pthread_mutex_unlock(&startLock); return failure("Could not start the embedded Java runtime."); }
            // The JVM handles SIGPIPE and SIGXFSZ only to ignore them, but its handler first reads the
            // signal's pc, which Zero cannot do, so it aborts the app instead. A write to a closed
            // socket raises SIGPIPE (the player leaving the media proxy mid-stream); ignore both here
            // so such writes fail with an IOException as on other platforms.
            signal(SIGPIPE, SIG_IGN); signal(SIGXFSZ, SIG_IGN);
            jclass local=(*env)->FindClass(env,"tvbox/runtime/AppleBootstrap");
            if (local) { bootstrap=(*env)->NewGlobalRef(env,local); (*env)->DeleteLocalRef(env,local); }
            if (bootstrap) requestMethod=(*env)->GetStaticMethodID(env,bootstrap,"request","(Ljava/lang/String;)Ljava/lang/String;");
            if (requestMethod) watchMemoryPressure(resourcePath);
        }
        pthread_mutex_unlock(&startLock);
        if (!env && (*runtimeVM)->AttachCurrentThread(runtimeVM,(void **)&env,NULL) != JNI_OK) {
            return failure("Could not attach the plugin worker.");
        }
        if ((*env)->ExceptionCheck(env) || !requestMethod) {
            (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); failed=YES;
            return failure("Could not initialize the plugin libraries. See diagnostic logs.");
        }
        NSString *requestText = @(requestJSON);
        NSUInteger length = requestText.length;
        unichar *characters = malloc((length + 1) * sizeof(unichar));
        [requestText getCharacters:characters range:NSMakeRange(0,length)];
        jstring input=(*env)->NewString(env,(const jchar *)characters,(jsize)length);
        free(characters);
        jstring output=(jstring)(*env)->CallStaticObjectMethod(env,bootstrap,requestMethod,input);
        (*env)->DeleteLocalRef(env,input);
        char *result=NULL;
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env);
            result=failure("The embedded plugin request failed. See diagnostic logs.");
        } else if(output) {
            const jchar *characters=(*env)->GetStringChars(env,output,NULL);
            NSString *text=[[NSString alloc] initWithCharacters:(const unichar *)characters length:(NSUInteger)(*env)->GetStringLength(env,output)];
            result=strdup(text.UTF8String);
            (*env)->ReleaseStringChars(env,output,characters); (*env)->DeleteLocalRef(env,output);
        } else result=failure("The plugin returned no response.");
        (*runtimeVM)->DetachCurrentThread(runtimeVM);
        return result;
    }
}
