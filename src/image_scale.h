#ifndef ANVIL_IMAGE_SCALE_H
#define ANVIL_IMAGE_SCALE_H

#include <stdbool.h>
#include <SDL3/SDL.h>

/*
** Draw `src` scaled to the rectangle x, y, w, h of `dst`, with bilinear filtering.
** Only the part inside the clip rect of `dst` is computed, so work and memory follow the
** visible area, not the scaled image size. Each destination pixel samples the same source
** point for any clip rect, so separate clipped draws join without seams.
** `color` multiplies the image, and its alpha sets the opacity.
*/
bool image_scale_blit(SDL_Surface *src, SDL_Surface *dst, double x, double y, double w, double h,
                      SDL_Color color);

#endif
