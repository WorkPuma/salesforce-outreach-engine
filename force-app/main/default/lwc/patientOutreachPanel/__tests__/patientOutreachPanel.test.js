import { createElement } from "lwc";
import PatientOutreachPanel from "c/patientOutreachPanel";
import getPatientWorkspace from "@salesforce/apex/OutreachWorkbenchController.getPatientWorkspace";
import getRecentEvents from "@salesforce/apex/OutreachWorkbenchController.getRecentEvents";

jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.getPatientWorkspace",
  () => ({
    __esModule: true,
    default: require("@salesforce/sfdx-lwc-jest").createApexTestWireAdapter(
      jest.fn()
    )
  }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.getRecentEvents",
  () => ({
    __esModule: true,
    default: require("@salesforce/sfdx-lwc-jest").createApexTestWireAdapter(
      jest.fn()
    )
  }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.recordSoftHold",
  () => ({ __esModule: true, default: jest.fn().mockResolvedValue(null) }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.logOutcome",
  () => ({ __esModule: true, default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.silenceNeed",
  () => ({ __esModule: true, default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.unsilenceNeed",
  () => ({ __esModule: true, default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "lightning/uiObjectInfoApi",
  () => {
    const { createLdsTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return {
      getObjectInfo: createLdsTestWireAdapter(jest.fn()),
      getPicklistValues: createLdsTestWireAdapter(jest.fn())
    };
  },
  { virtual: true }
);

const flushPromises = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

afterEach(() => {
  while (document.body.firstChild)
    document.body.removeChild(document.body.firstChild);
  jest.clearAllMocks();
});

test("renders workspace needs and recent events", async () => {
  const element = createElement("c-patient-outreach-panel", {
    is: PatientOutreachPanel
  });
  element.recordId = "001";
  document.body.appendChild(element);
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001",
    status: "Claimed",
    priority: "STAT",
    points: 90,
    nextAction: "Call",
    recommendedAction: "Call",
    ownerName: "PES",
    rationaleSource: "RuleEngine",
    needs: [
      {
        id: "n01",
        needType: "AWV",
        displayLabel: "AWV due",
        priority: "STAT",
        points: 90
      }
    ]
  });
  getRecentEvents.emit([
    {
      id: "e01",
      eventType: "Claimed",
      eventAt: "2026-07-19T00:00:00.000Z",
      actorName: "PES"
    }
  ]);
  await flushPromises();
  expect(element.shadowRoot.querySelectorAll(".need-tile")).toHaveLength(1);
  expect(element.shadowRoot.querySelector(".urgency-path")).not.toBeNull();
  expect(element.shadowRoot.querySelector(".timeline")).not.toBeNull();
  expect(element.shadowRoot.textContent).toContain("Log outcome");
});

test("highlights active urgency path and queue score", async () => {
  const element = createElement("c-patient-outreach-panel", {
    is: PatientOutreachPanel
  });
  element.recordId = "001";
  document.body.appendChild(element);
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001",
    status: "Claimed",
    priority: "Urgent",
    points: 90,
    nextAction: "Call patient",
    recommendedAction: "Call patient",
    rationale:
      "This patient needs outreach for an Annual Wellness Visit (Urgent · 90).",
    ownerName: "PES",
    needs: [
      {
        id: "n01",
        needType: "AWV",
        displayLabel: "Annual Wellness Visit",
        priority: "Urgent",
        points: 90
      }
    ]
  });
  getRecentEvents.emit([]);
  await flushPromises();

  const activeStage = element.shadowRoot.querySelector(
    ".urgency-path__stage_active"
  );
  expect(activeStage).not.toBeNull();
  expect(activeStage.textContent).toContain("Urgent");
    expect(element.shadowRoot.textContent).toContain("Annual Wellness Visit");
});
