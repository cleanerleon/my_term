#include <stddef.h>
#include <stdint.h>
void wind_sha3_512(const uint8_t *data, size_t length, uint8_t output[64]);
void wind_pbkdf2_sha3_512(const uint8_t *password, size_t password_length, const uint8_t *salt, size_t salt_length, uint32_t rounds, uint8_t output[48]);
