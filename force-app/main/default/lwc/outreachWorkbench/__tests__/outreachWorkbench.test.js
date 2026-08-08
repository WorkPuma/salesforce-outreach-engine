import { createElement } from "lwc";
import OutreachWorkbench from "c/outreachWorkbench";
import getQueueDashboard from "@salesforce/apex/OutreachQueueService.getQueueDashboard";

jest.mock(
  "@salesforce/apex/OutreachQueueService.getQueueDashboard",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.openUnclaimedEpisode",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.recordSoftHold",
  () => ({ default: jest.fn() }),
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
  jest.useRealTimers();
});

test("renders queue panels and priority load from dashboard", async () => {
  getQueueDashboard.mockResolvedValue({
    canSupervise: false,
    supervisorMode: false,
    omniEnabled: false,
    kpis: [{ key: "NO_NEXT", label: "No next visit", patientCount: 1 }],
    priorityLoad: {
      urgentCount: 7,
      routineCount: 3,
      statCount: 0,
      totalCount: 10,
      percentUrgent: 70
    },
    recentlyViewed: [],
    recentlyWorked: [],
    unclaimed: [
      {
        episodeId: "a01",
        accountId: "001",
        patientName: "Patient",
        accountUrl: "/lightning/r/Account/001/view",
        status: "Unclaimed",
        priority: "Urgent",
        needsSummary: "No next visit",
        careGaps: [{ key: "NO_NEXT", label: "No next visit" }],
        dueDate: "2026-07-20"
      }
    ]
  });

  const element = createElement("c-outreach-workbench", {
    is: OutreachWorkbench
  });
  document.body.appendChild(element);
  await flushPromises();

  expect(element.shadowRoot.querySelector(".ow-donut__pct").textContent).toBe(
    "70%"
  );
  const unclaimed = element.shadowRoot.querySelector(
    'section[aria-label="Queue"]'
  );
  expect(unclaimed).toBeTruthy();
  expect(unclaimed.textContent).toContain("Patient");
  expect(unclaimed.textContent).toContain("! Urgent");
});


const dashboardPayload = {
  canSupervise: false,
  supervisorMode: false,
  omniEnabled: false,
  kpis: [{ key: "NO_NEXT", label: "No next visit", patientCount: 1 }],
  priorityLoad: {
    urgentCount: 7,
    routineCount: 3,
    statCount: 0,
    totalCount: 10,
    percentUrgent: 70
  },
  recentlyViewed: [],
  recentlyWorked: [],
  unclaimed: []
};

test("soft-refreshes the queue every 60 seconds without spinner", async () => {
  jest.useFakeTimers();
  getQueueDashboard.mockResolvedValue(dashboardPayload);

  const element = createElement("c-outreach-workbench", {
    is: OutreachWorkbench
  });
  document.body.appendChild(element);
  await flushPromises();
  expect(getQueueDashboard).toHaveBeenCalledTimes(1);

  getQueueDashboard.mockClear();
  getQueueDashboard.mockResolvedValue({
    ...dashboardPayload,
    priorityLoad: { ...dashboardPayload.priorityLoad, percentUrgent: 40 }
  });

  jest.advanceTimersByTime(120000);
  await flushPromises();

  expect(getQueueDashboard).toHaveBeenCalledTimes(1);
  expect(element.shadowRoot.querySelector(".ow-donut__pct").textContent).toBe(
    "40%"
  );
});

test("clears the refresh interval on disconnect", async () => {
  jest.useFakeTimers();
  getQueueDashboard.mockResolvedValue(dashboardPayload);

  const element = createElement("c-outreach-workbench", {
    is: OutreachWorkbench
  });
  document.body.appendChild(element);
  await flushPromises();

  document.body.removeChild(element);
  await flushPromises();
  getQueueDashboard.mockClear();

  jest.advanceTimersByTime(120000);
  await flushPromises();
  expect(getQueueDashboard).not.toHaveBeenCalled();
});

test("soft-refreshes when the document becomes visible again", async () => {
  getQueueDashboard.mockResolvedValue(dashboardPayload);

  const element = createElement("c-outreach-workbench", {
    is: OutreachWorkbench
  });
  document.body.appendChild(element);
  await flushPromises();
  getQueueDashboard.mockClear();

  Object.defineProperty(document, "visibilityState", {
    configurable: true,
    get: () => "visible"
  });
  document.dispatchEvent(new Event("visibilitychange"));
  await flushPromises();

  expect(getQueueDashboard).toHaveBeenCalledTimes(1);
});
