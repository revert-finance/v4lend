# Hookathon Demo Voice-Over

## 40-Second Script

This demo runs on a live Unichain fork. We deploy the full Revert hook stack, initialize a hooked pool, and mint two positions: one wide ambient position to keep the pool tradable, and one narrow position that we move into the vault with zero debt.

Next, we activate three automations together: auto leverage, auto range, and a lower-side auto exit. Because the vault position starts below its target leverage, configuration itself immediately borrows and rebalances the position.

Then we push price upward. Auto range fires first, remints the NFT into a new range, and preserves the vault loan ownership and configuration.

Finally, we bring price back down. The lower auto-exit trigger fires, the hook removes liquidity, repays the debt, and cleanly closes the vaulted position.
