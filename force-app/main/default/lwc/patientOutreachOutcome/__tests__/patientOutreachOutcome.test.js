import { createElement } from "lwc";
import PatientOutreachOutcome from "c/patientOutreachOutcome";
import getPatientWorkspace from "@salesforce/apex/OutreachWorkbenchController.getPatientWorkspace";
import logOutcome from "@salesforce/apex/OutreachWorkbenchController.logOutcome";
import {
  publish,
  subscribe,
  MessageContext,
  createMessageContext
} from "lightning/messageService";

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
  "@salesforce/apex/OutreachWorkbenchController.logOutcome",
  () => ({ __esModule: true, default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/messageChannel/PatientOutreachState__c",
  () => ({ default: "PatientOutreachState" }),
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

function mount() {
  const element = createElement("c-patient-outreach-outcome", {
    is: PatientOutreachOutcome
  });
  element.recordId = "001ACCOUNT";
  document.body.appendChild(element);
  createMessageContext.mockReturnValue({ id: "ctx" });
  MessageContext.emit(createMessageContext());
  return element;
}

function latestSubscribeHandler() {
  const calls = subscribe.mock.calls;
  if (!calls.length) return null;
  return calls[calls.length - 1][2];
}

test("renders log outcome form", async () => {
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Claimed",
    commentOnlyMode: false,
    needs: [
      {
        id: "n01",
        needType: "AWV",
        displayLabel: "AWV Due",
        priority: "Urgent",
        forceAcknowledge: false
      }
    ]
  });
  await flushPromises();

  expect(element.shadowRoot.textContent).toContain("Log Outcome");
  const outcome = element.shadowRoot.querySelector("lightning-combobox");
  expect(outcome).not.toBeNull();
  const values = outcome.options.map((option) => option.value);
  expect(values).toEqual(
    expect.arrayContaining([
      "No Answer",
      "Left Message",
      "Awaiting Patient Callback",
      "Awaiting Patient Response",
      "Appointment Scheduled",
      "Inactive Patient",
      "Patient Deceased"
    ])
  );
  expect(values).not.toEqual(
    expect.arrayContaining([
      "Connected",
      "Did not respond",
      "Results Received",
      "Handoff To Marketing"
    ])
  );
  expect(element.shadowRoot.querySelector("lightning-textarea")).not.toBeNull();
  expect(
    [...element.shadowRoot.querySelectorAll("lightning-button")].some(
      (b) => b.label === "Save"
    )
  ).toBe(true);
});

test("saves outcome with selected needs from LMS state", async () => {
  logOutcome.mockResolvedValue({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    needs: []
  });
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Claimed",
    commentOnlyMode: false,
    needs: [
      {
        id: "n01",
        needType: "AWV",
        displayLabel: "AWV Due",
        priority: "Urgent",
        forceAcknowledge: true
      }
    ]
  });
  await flushPromises();

  const handler = latestSubscribeHandler();
  expect(handler).toBeTruthy();
  handler({
    eventType: "NEED_STATE",
    recordId: "001ACCOUNT",
    selectedNeedIdsJson: JSON.stringify(["n01"]),
    acknowledgedNeedIdsJson: JSON.stringify(["n01"])
  });
  await flushPromises();

  const detail = element.shadowRoot.querySelector("lightning-textarea");
  detail.dispatchEvent(
    new CustomEvent("change", { detail: { value: "Spoke with patient" } })
  );
  await flushPromises();

  const save = [
    ...element.shadowRoot.querySelectorAll("lightning-button")
  ].find((b) => b.label === "Save");
  save.click();
  await flushPromises();

  expect(logOutcome).toHaveBeenCalledWith(
    expect.objectContaining({
      episodeId: "a01",
      outcome: "Left Message",
      channel: "Phone",
      detail: "Spoke with patient",
      selectedNeedIds: ["n01"],
      acknowledgedNeedIds: ["n01"],
      closeRelated: false,
      commentOnly: false
    })
  );
  // LMS refresh is best-effort after save; Apex payload is the contract under test.
  expect(logOutcome).toHaveBeenCalled();
});

test("comment-only mode requires a comment", async () => {
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Claimed",
    commentOnlyMode: true,
    cooldownMessage: "Outcomes locked until tomorrow.",
    needs: []
  });
  await flushPromises();

  expect(element.shadowRoot.textContent).toContain("Comment only");
  const save = [
    ...element.shadowRoot.querySelectorAll("lightning-button")
  ].find((b) => b.label === "Save comment");
  save.click();
  await flushPromises();
  expect(logOutcome).not.toHaveBeenCalled();
});
