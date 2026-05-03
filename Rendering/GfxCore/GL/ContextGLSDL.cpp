#include "ContextGL.h"
#include "HeadersGL.h"
#include "rbx/Debug.h"
#include  <iostream>

#include <SDL2/SDL.h>
#include <SDL2/SDL_opengl.h>

namespace RBX
{
	namespace Graphics
	{
		class ContextGLSDL2 : public ContextGL
		{
		public:
			ContextGLSDL2(void* windowHandle)
				: sdlWindow(reinterpret_cast<SDL_Window*>(windowHandle))
				, glContext(nullptr)
			{
				#if defined(EMSCRIPTEN) || defined(__EMSCRIPTEN__)
					SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
					SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
					SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
				#else
					SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
					SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
					SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
				#endif

				glContext = SDL_GL_CreateContext(sdlWindow);
				if (!glContext)
				{
					throw RBX::runtime_error("SDL_GL_CreateContext failed: %s", SDL_GetError());
				}

				if (SDL_GL_MakeCurrent(sdlWindow, glContext) != 0)
				{
					throw RBX::runtime_error("SDL_GL_MakeCurrent failed: %s", SDL_GetError());
				}

				#if !defined(EMSCRIPTEN) && !defined(__EMSCRIPTEN__)
					SDL_GL_SetSwapInterval(0);
					glewInitRBX();
				#endif
			}

			~ContextGLSDL2()
			{
				if (glContext)
				{
					SDL_GL_DeleteContext(glContext);
					glContext = nullptr;
				}
			}

			virtual void setCurrent() override
			{
				if (SDL_GL_GetCurrentContext() != glContext)
				{
					if (SDL_GL_MakeCurrent(sdlWindow, glContext) != 0)
					{
						RBXASSERT(false);
					}
				}
			}

			virtual void swapBuffers() override
			{
				RBXASSERT(SDL_GL_GetCurrentContext() == glContext);
				SDL_GL_SwapWindow(sdlWindow);
			}

			virtual unsigned int getMainFramebufferId() override
			{
				return 0;
			}

			virtual bool isMainFramebufferRetina() override
			{
				return false;
			}

			virtual std::pair<unsigned int, unsigned int> updateMainFramebuffer(unsigned int width, unsigned int height) override
			{
				int w = 0, h = 0;
				SDL_GetWindowSize(sdlWindow, &w, &h);
				return std::make_pair(static_cast<unsigned int>(w), static_cast<unsigned int>(h));
			}

		private:
			SDL_Window* sdlWindow;
			SDL_GLContext glContext;
		};

		ContextGL* ContextGL::create(OSContext* context)
		{
			return new ContextGLSDL2(context->hWnd);
		}

	} // namespace Graphics
} // namespace RBX
