import chisel3._
import net.gamebub.framework.Core
import net.gamebub.framework.interface._

/**
 * Apple IIgs for Game Bub.
 *
 * This class only declares which framework interfaces the core uses and how
 * they are configured. All of the logic lives in SystemVerilog under rtl/:
 * the framework binds this IO bundle to the `iigs_gamebub` module
 * (rtl/gamebub/iigs_gamebub.sv) and prints that module's port template
 * during the build.
 */
class AppleIIgs extends Module with Core {
  // One MMCM generates every clock (rtl/gamebub/gb_clocks.sv):
  // 50 MHz x 20.625 = 1031.25 MHz VCO.
  val vcoHz = 1_031_250_000.0
  // The IIgs's 14.318 MHz master clock (CLK_14M), 0.03% fast. The video
  // pixel rate equals it, so gb_video_out takes one pixel per system clock.
  val systemHz = (vcoHz / 72).toInt
  // The LCD clock must keep the framework's ILI9806E line at <= 612 clocks
  // (floor(framePeriod * displayHz / 808); MacLC_GameBub FRAMEWORK_ISSUES #3):
  // 28.65 MHz gives 591.
  val displayHz = (vcoHz / 36).toInt
  // The MCU SPI sampling clock must be at least 160 MHz.
  val spiHz = (vcoHz / 6).toInt

  // The VGC's NTSC frame: 912 x 262 pixel clocks.
  val framePeriod = 912.0 * 262.0 / systemHz

  val io = IO(new Bundle {
    val clocks = new ClocksV0(
      clockSystemHz = systemHz,
      clockDisplayHz = displayHz,
      clockSpiHz = spiHz,
    )
    // Super Hi-Res 640 x 200 with pixel pairs averaged (gb_video_out.sv):
    // lossless for 320 mode, which games use, and scaled x2 to 640 x 400 on
    // the panel. The framework double-buffers it on chip: 2 x 320 x 200 x 9.
    val video = new VideoV0(
      videoWidth = 320,
      videoHeight = 200,
      colorDepthR = 3,
      colorDepthG = 3,
      colorDepthB = 3,
      framePeriod = framePeriod,
    )
    val audio = new AudioV0()
    val host = new HostV0()
    val input = new InputV0()
    // Fast RAM, ROMs and the disk images (map: rtl/gamebub/gb_host.sv).
    val sdram = new SdramV0(chips = 1)
    // Debug beacon, 3.3 V.
    val pmod = new PmodV0()
  })

  bindExtModule("iigs_gamebub", io, Map())
}
