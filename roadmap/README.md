# **Roadmap for PgFirstAid**

This is the comprehensive road-map for pgFirstAid. Yes, it is a planning document and yes it is absolutely needed. I am a father of three, work 45-50 hours a week at my jobby job, and spend my free time outside enjoying Mother Nature. The plan will help pace the development of this project and set milestones that I should be able to achieve while holding me accountable.
* * *
## **Requirements**

### **Agnostic to Hosting Method**

- Should be deploy-able to:

- Three major cloud providers (AWS/GCP/Azure)

- Kubernettes

- Bare Metal or Virtual Machine

- Queries can be executed by users with rights obtainable regardless of environment

- Most cloud providers restrict or simply do not allow for users to have root/superuser rights. So pgFirstAid needs to be able to run and pull the information needed without these rights


### **Compatible with Postgres 15 and Newer**

- Straightforward: focus will be supporting versions of Postgres 15 and up. Any older versions may work, but will be out of scope

### **Output Includes Recommendations and/or Link to Articles**

- Whatever pgFirstAid finds, the output will point out the "issue" or "area of improvement", provide recommendations on how to resolve and/or provide a link to documentation explaining how to troubleshoot the issue

- Output will be easy to export either via csv and can be exported via pg_cron job.

- Export targets should include s3/blob storage

- Local file system

- Optional parameter to auto create pg_cron job to have output saved to a table on a schedule


### **Collaborative From The Start**

- Any queries/statements used will include references to their authors. While I am, by profession, a DBA, I do not possess all the knowledge in the world on Postgres.

- PRs are encouraged. However, this project is a passion project and, therefore, is not my main priority in my life. I will get to the reviews when I can

- Issues will be addressed in the same manner as PRs.


### **Copy Left Licensing (GPLv3)**

- pgFirstAid will never become proprietary. Period. THe GPLv3 license provides the freedom to use,modify, and redistribute. More information on the license can be found [here](https://www.gnu.org/licenses/quick-guide-gplv3.en.html)

## **Scope**

### **Checks to include, at the start**

####  **Server Settings**

1.  Recommended settings
2.  based on host
3.  based on provider (aws/gcp/azure)
4.  Logical Replication (set?)
5.  Authentication Methods enabled/in use
6.  Log Verbosity
7.  Log Location
8.  Log Size (current)
9.  List of log files
10. Data file(s) location
11. Settings not set to at engine default (edited by user)
12. Current PG version
13. Last update received (what time was the server updated)
14. Installed Extensions and other Libraries
15. Cron Jobs

#### **User Management**

1.  List of Admin Users (superuser/all privileges to all tables/schemas/etc)
2.  List of Roles
3.  Users with only Select granted (without role)
4.  Users with rights w/o role assigned
5.  List of user created roles
6.  Users with rights more than Select (without role)

#### **Schema/Database Level**

1.  Tables w/o primary keys
2.  Tables w/o indexes
3.  Size of Database(s)
4.  Size of Schema
5.  Size of Tables
6.  Table Counts (per Database/per Schema)
7.  Empty Tables
8.  Replication Slots
9.  Publications (and their tables)

#### **Health**

1.  Unused Indexes
2.  Vacuum checks
3.  Top wait stats
4.  Up-time (time since last reboot)
5.  Queries with High Estimated Cost vs Actual Costs
6.  Last Vacuum Time/Vacuum stats
7.  Foreign keys without indexes
8.  Indexes with null values
9.  Duplicated foreign keys
10. Duplicated indexes
11. Primary keys
12. Index Bloat
13. WAL Bloat (space WAL is holding onto)
14. Tables in Postgres table (don't you dare!)
15. md5 authentication set in pg_hba.conf.

### **Documentation**

- Website for Branding and hosting all documentation for pgFirstAid
- Install docs in github (advanced installs/deployment methods on website)

### **Branding**

- Logo
- Website

## **Out of Scope**

These are checks I will have to do some research on how to best integrate them into pgFirstAid

1.  Available Versions to upgrade?
2.  Known issues with current version
3.  pgToast related things
4.  Detected Corruption (long live pgcheck)
5.  Backup metrics/tracking/etc?
6.  .....built in maintenance plan (Ola, I will make you proud)

## **Time Line/Milestones**

This is a project that I will be doing during my free time, so I have to set realistic expectations on how I set my milestones. With this in mind, I will be targeting milestones based on work completed.

### **Milestone: Framework**

- Function Format Created
- Output Format Created
- 5 Checks Implemented
- Readme

### **Milestone: Checks and pg_cron Implementation**

- Add optional step to enable pg_cron extension and notify to reboot
- Add default job to create output to table (creating new user database) and set cron schedule
- 5-10 Checks Implemented

### **Milestone: Checks and Documentation**

- 5-10 Checks Implemented
- Begin adding documentation on checks (including links to relevant articles/sites)

### **Milestone: Checks and Branding**

- 5-10 Checks Implemented with documentation
- Identify artist to create project logo (AI doesn't count folks....)
- Website with basic information and mainly documentation site.

### **Milestone: Checks and "Go Live"**

- 5-10 checks Implemented with documentation
- checks backlog created and moved checks yet to be completed into backlog
- Promote outside of github (Socials, Posts on blog sites, etc)

### **SCALE 23x**

- Submit talk and present pgFirstAid at SCALE 23x
- Cry
- Laugh
- Show people my nix-flake

## **Final Thoughts/Comments**

This is going to be a long road and I am ready for it. I am both excited and absolutely terrified because I feel like there are so many much more talented engineers out there that can do a better job than me at this. I cannot do this alone, and I will be using queries that others have written in these checks. Their work will ONLY be included if they give permission and they will be acknowledged for their contributions. Anyone with existing queries or checks that they would like to submit are welcome to, as long as your work does not conflict with the GPLv3 license.

### **Donations**

While the cost of this project is more "my time", I do need to purchase some equipment to host the various versions of Postgres (15+) for testing pgFirstAid. In no way do I expect anything, so my intention is to purchase what I need with my own money. This is a passion project and professional development. Therefore, it is an investment in myself.

In addition, it would be great to be able to host a local instance of Ollama to provide any assistance along the way. Any code written or provided by the LLM that I do not change will be called out in documentation for absolute FULL transparency. If you wish to donate hardware, currency, or your expertise, please contact me at justin@randoneering.tech. I don't have any "fund me" accounts or anything like that as of writing this document (Late May 2025), but if that changes I will post that in the github repo and website.

### **Expenses**

This is just for me, but I will track monthly costs for this project. That way, if someone wants to donate to the project they can see my monthly costs and can track where the donation goes to. Any services I need will be self hosted and contained. The only subscriptions I can see myself taking on are domain registrations, mail hosting, and travel expenses to conferences (like SCALE!). I will provid this "report" every month and larger report every quarter. Why? Well, as my wife always says, because "I am insane."

### **Thank you!**

Huge thank you to my mentors (David and Michael); you both have pushed me to learn a lot about myself professionally, and I cannot thank you enough. I only hope to provide the same level of mentorship to some poor soul(s) willing to deal with my ADHD and Perfectionism.

To my wife and kids; you drive me nuts and take all the money I earn but I still love you. Please give me some grace as I work through this project!
