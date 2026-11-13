# Local inference

- 2026-11-13: Published `mlx-community/sam-audio-large` config uses transformer dimensions 1536/12 layers while the installed checkpoint headers show 2816/22 layers; pinned MLX Audio silently skips incompatible weights. Micromix corrects this recognized config in memory and validates required parameter shapes; full-model loading and audio quality remain unverified pending user-led testing. See PLAN task 22 and `services/local-inference/MODELS.md`.
