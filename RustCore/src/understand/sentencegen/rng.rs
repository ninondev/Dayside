// SPDX-License-Identifier: GPL-3.0-only
//! 极简 xorshift64* 伪随机数发生器，无外部依赖，保证同种子结果确定。

pub(crate) struct Rng {
    state: u64,
}

impl Rng {
    // 用种子构造；零种子会被替换成固定常数，避免全零状态。
    pub(crate) fn new(seed: u64) -> Self {
        let state = if seed == 0 { 0x9E37_79B9_7F4A_7C15 } else { seed };
        Rng { state }
    }

    // 产生下一个 64 位随机数（xorshift64*）。
    fn next(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    // 返回 0..n 的均匀整数。
    pub(crate) fn bound(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}
