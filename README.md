# 🚌 SmartTransit

A modern smart transportation management platform for bus tracking, route management, and passenger bookings.

SmartTransit is a full-stack solution that connects passengers, transport operators, and administrators through a single, centralized digital platform.

[![Flutter](https://img.shields.io/badge/Frontend-Flutter-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Node.js](https://img.shields.io/badge/Backend-Node.js-339933?logo=node.js&logoColor=white)](https://nodejs.org)
[![License](https://img.shields.io/badge/License-Educational-blue)](#license)

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Technology Stack](#technology-stack)
- [Project Structure](#project-structure)
- [Getting Started](#getting-started)
- [Environment Variables](#environment-variables)
- [User Roles](#user-roles)
- [Project Objectives](#project-objectives)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)
- [Developer](#developer)

---

## Overview

SmartTransit provides a digital solution for managing transportation services, improving the passenger experience while simplifying the management of vehicles, routes, schedules, and bookings.

The project consists of a **Flutter frontend**, a **Node.js backend**, and **database integration**.

---

## Features

### User Features
- User registration and authentication
- View available routes and transportation services
- View schedules
- Book transportation services
- Manage personal profile
- Access booking and trip information

### Transportation Features
- Vehicle management
- Route management
- Schedule management
- Passenger booking management
- Live tracking support

### Admin Features
- Secure administrative access
- Manage users
- Manage routes and vehicles
- Update schedules
- Monitor bookings
- Manage transportation records

---

## Architecture

```text
Flutter Frontend
       │
       │  HTTP / API Requests
       ▼
Node.js Backend
       │
       │  Database Queries
       ▼
Database
```

---

## Technology Stack

| Layer      | Technologies                                  |
|------------|------------------------------------------------|
| Frontend   | Flutter, Dart                                   |
| Backend    | Node.js, JavaScript                             |
| Database   | Database management for users, routes, vehicles, and bookings |
| Tooling    | Git, GitHub, Visual Studio Code, Android Studio, npm |

---

## Project Structure

```text
SmartTransit/
│
├── .vscode/                  # VS Code configuration
├── backend/                  # Backend source code
├── database/                 # Database files and configuration
│
├── flutter_frontend/         # Flutter application
│   ├── android/
│   ├── ios/
│   ├── lib/
│   ├── linux/
│   ├── macos/
│   ├── windows/
│   └── pubspec.yaml
│
├── .env.example               # Environment variable example
├── package.json                # Node.js dependencies
├── package-lock.json
├── server.js                   # Backend entry point
│
└── README.md
```

---

## Getting Started

### Prerequisites

Make sure you have installed:

- [Node.js](https://nodejs.org)
- [Flutter SDK](https://flutter.dev)
- Dart SDK (bundled with Flutter)
- Git
- Android Studio or Visual Studio Code

Verify your Flutter installation:

```bash
flutter doctor
```

### 1. Clone the repository

```bash
git clone https://github.com/Hammal04/SmartTransit.git
cd SmartTransit
```

### 2. Backend setup

Install dependencies:

```bash
npm install
```

Create a `.env` file based on `.env.example` (see [Environment Variables](#environment-variables)).

Start the backend server:

```bash
node server.js
```

Or, if a development script is configured:

```bash
npm run dev
```

### 3. Flutter frontend setup

Navigate to the Flutter app:

```bash
cd flutter_frontend
```

Install dependencies:

```bash
flutter pub get
```

Run the application:

```bash
flutter run
```

### Run on different platforms

| Platform | Command                     |
|----------|------------------------------|
| Android  | `flutter run`                |
| Windows  | `flutter run -d windows`     |
| Web      | `flutter run -d chrome`      |

---

## Environment Variables

Create a `.env` file in the project root:

```env
PORT=5000
DATABASE_URL=your_database_connection_string
JWT_SECRET=your_secure_secret
```

> ⚠️ **Important:** Never commit your `.env` file or any sensitive credentials to GitHub.

---

## User Roles

| Role  | Permissions                                                  |
|-------|----------------------------------------------------------------|
| User  | Browse routes, view schedules, manage bookings and profile     |
| Admin | Manage users, vehicles, routes, schedules, and bookings        |

---

## Project Objectives

SmartTransit aims to:

- Digitize transportation management
- Improve the passenger experience
- Simplify route and schedule management
- Reduce manual booking processes
- Support efficient transportation monitoring
- Provide a scalable digital transportation solution

---

## Roadmap

- [ ] Real-time GPS tracking
- [ ] Interactive maps integration
- [ ] Online payment system
- [ ] Push notifications
- [ ] AI-powered route recommendations
- [ ] Advanced analytics dashboard
- [ ] Driver ratings and reviews
- [ ] Multi-language support

---

## Contributing

Contributions are welcome!

1. Fork the repository
2. Create a new branch
   ```bash
   git checkout -b feature/your-feature
   ```
3. Make your changes
4. Commit your changes
   ```bash
   git commit -m "Add new feature"
   ```
5. Push your branch
   ```bash
   git push origin feature/your-feature
   ```
6. Open a Pull Request

---

## License

This project is intended for educational and development purposes.

---

## Developer

**Hammal Baloch**

- GitHub: [github.com/Hammal04](https://github.com/Hammal04)
- LinkedIn: https://www.linkedin.com/in/hammal9

---

<div align="center">

### 🚌 SmartTransit
**Building smarter and more connected transportation experiences.**
Made with Flutter, Node.js, and modern web technologies.

</div>
