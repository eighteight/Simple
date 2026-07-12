/*
    SimpleRenderer.m
	Syphon (SDK)

    Copyright 2010-2011 bangnoise (Tom Butterworth) & vade (Anton Marini).
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
    (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
    ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SimpleRenderer.h"
#import <OpenGL/gl3.h>

// A rotating wheel in the spirit of the Quartz Composer composition the
// original Simple Server shipped with: an outer ring carrying three arrows,
// a counter-rotating inner ring, a central disc and an orbiting dot.
// Drawn with OpenGL 3.2 Core Profile.

static NSString * const kVertexSource = @"#version 150\n"
"in vec2 pos;\n"
"uniform float angle;\n"
"uniform vec2 scale;\n"
"uniform vec2 offset;\n"
"uniform float aspect;\n"     // width / height
"void main() {\n"
"    float c = cos(angle), s = sin(angle);\n"
"    vec2 p = mat2(c, s, -s, c) * (pos * scale) + offset;\n"
"    p.x /= aspect;\n"
"    gl_Position = vec4(p, 0.0, 1.0);\n"
"}\n";

static NSString * const kFragmentSource = @"#version 150\n"
"uniform vec4 color;\n"
"out vec4 fragColor;\n"
"void main() { fragColor = color; }\n";

enum {
    kSegments = 96
};

@implementation SimpleRenderer {
    BOOL setupDone;
    NSTimeInterval startTime;
    GLuint program;
    GLuint vao;
    GLuint vbo;
    GLint uAngle, uScale, uOffset, uAspect, uColor;

    // offsets (in vertices) and counts of each piece in the buffer
    GLint discFirst, discCount;
    GLint ringFirst, ringCount;
    GLint circleFirst, circleCount;
    GLint arrowFirst, arrowCount;
    GLint lineFirst, lineCount;
}

static GLuint compileShader(GLenum type, NSString *source)
{
    GLuint shader = glCreateShader(type);
    const char *src = [source UTF8String];
    glShaderSource(shader, 1, &src, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok)
    {
        char log[512];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        NSLog(@"Shader compile failed: %s", log);
    }
    return shader;
}

- (void)setupGL
{
    GLuint vs = compileShader(GL_VERTEX_SHADER, kVertexSource);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER, kFragmentSource);
    program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "pos");
    glLinkProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    uAngle  = glGetUniformLocation(program, "angle");
    uScale  = glGetUniformLocation(program, "scale");
    uOffset = glGetUniformLocation(program, "offset");
    uAspect = glGetUniformLocation(program, "aspect");
    uColor  = glGetUniformLocation(program, "color");

    // Build all the geometry, in a unit coordinate space, into one buffer
    NSMutableData *data = [NSMutableData data];
    GLint cursor = 0;

    // 1: unit disc (triangle fan) — also reused for the orbiting dot
    {
        discFirst = cursor;
        GLfloat center[2] = {0, 0};
        [data appendBytes:center length:sizeof(center)];
        for (int i = 0; i <= kSegments; i++)
        {
            float a = 2.0 * M_PI * i / kSegments;
            GLfloat v[2] = {cosf(a), sinf(a)};
            [data appendBytes:v length:sizeof(v)];
        }
        discCount = kSegments + 2;
        cursor += discCount;
    }

    // 2: annulus, radii 0.86..1.0 (triangle strip) — scaled for both rings
    {
        ringFirst = cursor;
        for (int i = 0; i <= kSegments; i++)
        {
            float a = 2.0 * M_PI * i / kSegments;
            GLfloat v[4] = {0.86f * cosf(a), 0.86f * sinf(a), cosf(a), sinf(a)};
            [data appendBytes:v length:sizeof(v)];
        }
        ringCount = (kSegments + 1) * 2;
        cursor += ringCount;
    }

    // 3: unit circle outline (line loop)
    {
        circleFirst = cursor;
        for (int i = 0; i < kSegments; i++)
        {
            float a = 2.0 * M_PI * i / kSegments;
            GLfloat v[2] = {cosf(a), sinf(a)};
            [data appendBytes:v length:sizeof(v)];
        }
        circleCount = kSegments;
        cursor += circleCount;
    }

    // 4: one arrow, swept along the outer ring at angle 0 (two triangles):
    //    a tangential tail across the ring ending in a tip
    {
        arrowFirst = cursor;
        float rIn = 0.83f, rOut = 1.03f, rMid = 0.93f;
        float aTail = -0.28f, aNeck = 0.10f, aTip = 0.34f;
        GLfloat tail[6] = {
            rIn  * cosf(aTail), rIn  * sinf(aTail),
            rOut * cosf(aTail), rOut * sinf(aTail),
            rIn  * cosf(aNeck), rIn  * sinf(aNeck)};
        GLfloat head[6] = {
            rOut * cosf(aTail), rOut * sinf(aTail),
            rIn  * cosf(aNeck), rIn  * sinf(aNeck),
            rMid * cosf(aTip),  rMid * sinf(aTip)};
        [data appendBytes:tail length:sizeof(tail)];
        [data appendBytes:head length:sizeof(head)];
        arrowCount = 6;
        cursor += arrowCount;
    }

    // 5: a diameter line
    {
        lineFirst = cursor;
        GLfloat v[4] = {-1, 0, 1, 0};
        [data appendBytes:v length:sizeof(v)];
        lineCount = 2;
        cursor += lineCount;
    }

    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, data.length, data.bytes, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);

    startTime = [NSDate timeIntervalSinceReferenceDate];
    setupDone = YES;
}

- (void)drawMode:(GLenum)mode first:(GLint)first count:(GLint)count
           angle:(float)angle scale:(NSSize)scale offset:(NSPoint)offset
             red:(float)r green:(float)g blue:(float)b alpha:(float)a
{
    glUniform1f(uAngle, angle);
    glUniform2f(uScale, scale.width, scale.height);
    glUniform2f(uOffset, offset.x, offset.y);
    glUniform4f(uColor, r, g, b, a);
    glDrawArrays(mode, first, count);
}

- (void)render:(NSSize)dimensions
{
    if (!setupDone)
    {
        [self setupGL];
    }

    glViewport(0, 0, dimensions.width, dimensions.height);
    glClearColor(0.0, 0.0, 0.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(program);
    glBindVertexArray(vao);
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    float aspect = dimensions.height > 0 ? dimensions.width / dimensions.height : 1.0;
    glUniform1f(uAspect, aspect);

    // elapsed time since start: keep the value small, as float precision
    // (and GPU sin/cos) fall apart on huge absolute timestamps
    float t = (float)([NSDate timeIntervalSinceReferenceDate] - startTime);
    float spin = t * 0.6;                 // outer ring, radians/sec

    #define WHEEL 0.82f                   // overall radius in clip space

    // outer ring with three arrows, rotating
    [self drawMode:GL_TRIANGLE_STRIP first:ringFirst count:ringCount
             angle:spin scale:NSMakeSize(WHEEL, WHEEL) offset:NSMakePoint(0, 0)
               red:0.75 green:0.78 blue:0.82 alpha:0.55];
    for (int i = 0; i < 3; i++)
    {
        [self drawMode:GL_TRIANGLES first:arrowFirst count:arrowCount
                 angle:spin + i * (2.0 * M_PI / 3.0)
                 scale:NSMakeSize(WHEEL, WHEEL) offset:NSMakePoint(0, 0)
                   red:0.62 green:0.65 blue:0.70 alpha:0.9];
    }

    // inner ring, counter-rotating (annulus scaled down)
    [self drawMode:GL_TRIANGLE_STRIP first:ringFirst count:ringCount
             angle:-spin * 0.7 scale:NSMakeSize(WHEEL * 0.72f, WHEEL * 0.72f)
            offset:NSMakePoint(0, 0)
               red:0.25 green:0.27 blue:0.30 alpha:0.85];

    // central disc
    [self drawMode:GL_TRIANGLE_FAN first:discFirst count:discCount
             angle:0 scale:NSMakeSize(WHEEL * 0.42f, WHEEL * 0.42f)
            offset:NSMakePoint(0, 0)
               red:0.82 green:0.86 blue:0.90 alpha:1.0];

    // thin circle and a slowly turning diameter over everything
    [self drawMode:GL_LINE_LOOP first:circleFirst count:circleCount
             angle:0 scale:NSMakeSize(WHEEL * 0.56f, WHEEL * 0.56f)
            offset:NSMakePoint(0, 0)
               red:1.0 green:1.0 blue:1.0 alpha:0.5];
    [self drawMode:GL_LINES first:lineFirst count:lineCount
             angle:spin * 0.35 scale:NSMakeSize(WHEEL * 0.98f, WHEEL * 0.98f)
            offset:NSMakePoint(0, 0)
               red:1.0 green:1.0 blue:1.0 alpha:0.35];

    // the blue dot, orbiting inside the disc
    float dotAngle = -t * 1.5;
    NSPoint dotPos = NSMakePoint(WHEEL * 0.28f * cosf(dotAngle),
                                 WHEEL * 0.28f * sinf(dotAngle));
    [self drawMode:GL_TRIANGLE_FAN first:discFirst count:discCount
             angle:0 scale:NSMakeSize(WHEEL * 0.05f, WHEEL * 0.05f)
            offset:dotPos
               red:0.18 green:0.56 blue:0.94 alpha:1.0];

    glDisable(GL_BLEND);
    glBindVertexArray(0);
    glUseProgram(0);
}
@end
