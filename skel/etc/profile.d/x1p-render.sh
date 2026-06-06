# Surface Pro 11 — render environment (static default for hw-accelerated mode)
# This file is overwritten at login-shell time by x1p-render-setup.service.
# The service runs before display-manager.service, so by the time a graphical
# session starts this file already reflects the correct mode.
#
# If x1p-render-setup.service has not run (e.g. single-user mode), this default
# enables Freedreno/Turnip so that a manual `startx` works without extra steps.

export LIBGL_ALWAYS_SOFTWARE=0
export GALLIUM_DRIVER=freedreno
export MESA_LOADER_DRIVER_OVERRIDE=freedreno
# Turnip (Vulkan) ICD — installed by mesa-vulkan-drivers on aarch64
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
