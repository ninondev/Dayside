#ifndef DAYSIDE_CORE_H
#define DAYSIDE_CORE_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
typedef struct { uint8_t *data; size_t len; } MTBuffer;
uint32_t mt_core_abi_version(void);
MTBuffer mt_core_call(const uint8_t *data, size_t len);
void mt_core_free(MTBuffer buffer);
typedef struct { double sunrise; double sunset; int32_t kind; } MTSolarResult;
typedef struct { int64_t day; double fraction; } MTLocalComponents;
MTLocalComponents mt_local_components(double unix_time, int32_t offset);
double mt_clock_boundary(double unix_time, bool seconds);
int32_t mt_solar_minute(double fraction);
MTSolarResult mt_solar_compute(int32_t year, int32_t month, int32_t day, double lat, double lon, int32_t offset);
MTSolarResult mt_solar_cached(double lat, double lon, const uint8_t *zone, size_t len, int64_t day);
void mt_solar_store(double lat, double lon, const uint8_t *zone, size_t len, int64_t day, MTSolarResult value);
double mt_reference_date(double unix_time, double offset);
bool mt_is_scrubbing(double offset);
double mt_legible_opacity(double opacity);
typedef double (*MTMeasure)(void *context, const uint8_t *text, size_t len);
MTBuffer mt_label_fit(const uint8_t *data, size_t len, double max_width, void *context, MTMeasure measure);
/* 地形交给 Rust 一次（灰度，覆盖纬度 north…south），面板与地球窗都关了就放掉；
   地图按此刻的太阳逐像素上色，写进宿主给的 RGBA8 缓冲（width * height * 4 字节）。 */
bool mt_sky_relief_set(const uint8_t *gray, uint32_t width, uint32_t height, double north, double south);
void mt_sky_relief_release(void);
bool mt_sky_terrain_save(const char *path);
bool mt_sky_terrain_map(const char *path);
bool mt_sky_map_raster(double instant, uint32_t width, uint32_t height, double north, double south, double lights, uint8_t *out, size_t len, double ppp, bool large);
/* 屏幕上的地图：直接画进宿主的 IOSurface（每行 stride 字节，bgra 时按 BGRA 排）；ppp（每点几像素）> 0 时连晨昏线与太阳光晕一起画，
   large 是大图（太阳大一号）。量一块地方（像素坐标）的平均相对亮度（−1 = 算不出）。 */
bool mt_sky_map_raster_into(double instant, uint32_t width, uint32_t height, double north, double south, double lights, uint8_t *out, size_t stride, bool bgra, double ppp, bool large);
double mt_sky_map_luminance(double instant, uint32_t width, uint32_t height, double north, double south, double x0, double y0, double x1, double y1);
#endif
