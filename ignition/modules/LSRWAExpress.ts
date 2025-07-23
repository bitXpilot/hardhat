import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import "@nomicfoundation/hardhat-ignition-ethers";

export default buildModule("LSRWAExpress", (m) => {
  const lsr = m.contract("LSRWAExpress", ["0x5c4518abFE8f7560C1b12e01FD550c3a05377910", "0xDDA9bF84d2bBb543B49Dd9dB4f32de3c7b19aCa2"]);

  m.call(lsr, "requestDeposit", ["100000000000000000"]);

  return { lsr };
});