#include "value_bridge.h"

namespace coresim {

NSObject* JsValueToNSObject(Napi::Env env, Napi::Value value) {
  if (value.IsNull() || value.IsUndefined()) {
    return [NSNull null];
  }
  if (value.IsBoolean()) {
    return @(value.As<Napi::Boolean>().Value());
  }
  if (value.IsNumber()) {
    return @(value.As<Napi::Number>().DoubleValue());
  }
  if (value.IsString()) {
    return @(value.As<Napi::String>().Utf8Value().c_str());
  }
  if (value.IsBuffer()) {
    auto buffer = value.As<Napi::Buffer<uint8_t>>();
    return [NSData dataWithBytes:buffer.Data() length:buffer.Length()];
  }
  if (value.IsArray()) {
    auto array = value.As<Napi::Array>();
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:array.Length()];
    for (uint32_t i = 0; i < array.Length(); i++) {
      [result addObject:JsValueToNSObject(env, array.Get(i))];
    }
    return result;
  }
  if (value.IsObject()) {
    auto object = value.As<Napi::Object>();
    Napi::Array keys = object.GetPropertyNames();
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:keys.Length()];
    for (uint32_t i = 0; i < keys.Length(); i++) {
      Napi::Value key = keys.Get(i);
      NSString* nsKey = @(key.As<Napi::String>().Utf8Value().c_str());
      result[nsKey] = JsValueToNSObject(env, object.Get(key));
    }
    return result;
  }
  return [NSNull null];
}

Napi::Value NSObjectToJsValue(Napi::Env env, id object) {
  if (object == nil || object == [NSNull null]) {
    return env.Null();
  }
  if ([object isKindOfClass:[NSString class]]) {
    return Napi::String::New(env, [(NSString*)object UTF8String]);
  }
  if ([object isKindOfClass:[NSNumber class]]) {
    NSNumber* number = (NSNumber*)object;
    if (strcmp(number.objCType, @encode(BOOL)) == 0 || strcmp(number.objCType, @encode(char)) == 0) {
      return Napi::Boolean::New(env, number.boolValue);
    }
    return Napi::Number::New(env, number.doubleValue);
  }
  if ([object isKindOfClass:[NSArray class]]) {
    NSArray* array = (NSArray*)object;
    Napi::Array result = Napi::Array::New(env, array.count);
    for (NSUInteger i = 0; i < array.count; i++) {
      result[static_cast<uint32_t>(i)] = NSObjectToJsValue(env, array[i]);
    }
    return result;
  }
  if ([object isKindOfClass:[NSDictionary class]]) {
    NSDictionary* dict = (NSDictionary*)object;
    Napi::Object result = Napi::Object::New(env);
    for (NSString* key in dict) {
      result.Set([key UTF8String], NSObjectToJsValue(env, dict[key]));
    }
    return result;
  }
  if ([object isKindOfClass:[NSURL class]]) {
    return Napi::String::New(env, [[(NSURL*)object absoluteString] UTF8String]);
  }
  if ([object isKindOfClass:[NSUUID class]]) {
    return Napi::String::New(env, [[(NSUUID*)object UUIDString] UTF8String]);
  }
  if ([object isKindOfClass:[NSData class]]) {
    NSData* data = (NSData*)object;
    return Napi::Buffer<uint8_t>::Copy(env, static_cast<const uint8_t*>(data.bytes), data.length);
  }
  return Napi::String::New(env, [[object description] UTF8String]);
}

}  // namespace coresim
