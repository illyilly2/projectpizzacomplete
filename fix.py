python3 << 'PYFIX'
import re

# ============================================================================
# FIX DeviceGL.cpp
# ============================================================================
print("Fixing DeviceGL.cpp...")
with open('Rendering/GfxCore/GL/DeviceGL.cpp', 'r') as f:
    content = f.read()

# Fix 1: Wrap glEndQuery(GL_TIME_ELAPSED)
content = re.sub(
    r'(\s+)glEndQuery\(GL_TIME_ELAPSED\);',
    r'\1#ifndef __EMSCRIPTEN__\n\1glEndQuery(GL_TIME_ELAPSED);\n\1#endif',
    content
)

# Fix 2: Wrap glGetQueryObjectiv
content = re.sub(
    r'(\s+)glGetQueryObjectiv\(frameTimeQueryId, GL_QUERY_RESULT_AVAILABLE, &available\);',
    r'\1#ifndef __EMSCRIPTEN__\n\1glGetQueryObjectiv(frameTimeQueryId, GL_QUERY_RESULT_AVAILABLE, &available);\n\1#else\n\1available = GL_TRUE;\n\1#endif',
    content
)

# Fix 3: Wrap the if statements for glGetQueryObjectui64v
old_pattern = r'if \(glGetQueryObjectui64v\)\s+glGetQueryObjectui64v\(frameTimeQueryId, GL_QUERY_RESULT, &elapsed\);\s+else if \(glGetQueryObjectui64vEXT\)\s+glGetQueryObjectui64vEXT\(frameTimeQueryId, GL_QUERY_RESULT, &elapsed\);'
new_pattern = '''#ifndef __EMSCRIPTEN__
                    if (glGetQueryObjectui64v)
                        glGetQueryObjectui64v(frameTimeQueryId, GL_QUERY_RESULT, &elapsed);
                    else if (glGetQueryObjectui64vEXT)
                        glGetQueryObjectui64vEXT(frameTimeQueryId, GL_QUERY_RESULT, &elapsed);
#else
                    elapsed = 0;
#endif'''

content = re.sub(old_pattern, new_pattern, content, flags=re.DOTALL)

with open('Rendering/GfxCore/GL/DeviceGL.cpp', 'w') as f:
    f.write(content)
print("✓ DeviceGL.cpp fixed")

# ============================================================================
# FIX DeviceContextGL.cpp
# ============================================================================
print("Fixing DeviceContextGL.cpp...")
with open('Rendering/GfxCore/GL/DeviceContextGL.cpp', 'r') as f:
    content = f.read()

# Fix 1: Wrap glPushDebugGroup block
content = re.sub(
    r'if \(glPushDebugGroup\) // Requires GL4\.3.*?\n(\s+)\{\n(\s+)glPushDebugGroup\(GL_DEBUG_SOURCE_APPLICATION_ARB, 0, -1, text \);',
    r'#ifndef __EMSCRIPTEN__\n    if (glPushDebugGroup) // Requires GL4.3\n    {\n        glPushDebugGroup(GL_DEBUG_SOURCE_APPLICATION_ARB, 0, -1, text );',
    content
)

# Add endif after the closing brace of glPushDebugGroup
content = re.sub(
    r'(glPushDebugGroup\(GL_DEBUG_SOURCE_APPLICATION_ARB, 0, -1, text \);)\n(\s+)\}',
    r'\1\n\2}\n#endif',
    content,
    count=1
)

# Fix 2: Wrap glPopDebugGroup block
content = re.sub(
    r'if \(glPopDebugGroup\) // Requires GL4\.3.*?\n(\s+)\{\n(\s+)glPopDebugGroup\(\);',
    r'#ifndef __EMSCRIPTEN__\n    if (glPopDebugGroup) // Requires GL4.3\n    {\n        glPopDebugGroup();',
    content
)

# Add endif after first glPopDebugGroup call
content = re.sub(
    r'(if \(glPopDebugGroup\).*?glPopDebugGroup\(\);)\n(\s+)\}',
    r'\1\n\2}\n#endif',
    content,
    count=1,
    flags=re.DOTALL
)

# Fix 3: Wrap glDebugMessageInsert block
content = re.sub(
    r'if \(glDebugMessageInsert\) // Requires GL4\.3.*?\n(\s+)\{\n(\s+)glDebugMessageInsert\(GL_DEBUG_SOURCE_APPLICATION_ARB',
    r'#ifndef __EMSCRIPTEN__\n    if (glDebugMessageInsert) // Requires GL4.3\n    {\n        glDebugMessageInsert(GL_DEBUG_SOURCE_APPLICATION_ARB',
    content
)

# Add endif after glDebugMessageInsert call
content = re.sub(
    r'(glDebugMessageInsert\(GL_DEBUG_SOURCE_APPLICATION_ARB, GL_DEBUG_TYPE_MARKER, 0, GL_DEBUG_SEVERITY_NOTIFICATION, -1, text \);)\n(\s+)\}',
    r'\1\n\2}\n#endif',
    content
)

with open('Rendering/GfxCore/GL/DeviceContextGL.cpp', 'w') as f:
    f.write(content)
print("✓ DeviceContextGL.cpp fixed")

print("\n✅ Both files patched successfully!")
PYFIX