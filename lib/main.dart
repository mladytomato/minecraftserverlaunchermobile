package com.mc.serverlauncher

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.*
import java.net.URL
import java.util.Properties

// ==========================================
// 1. ФОНОВЫЙ СЕРВИС СЕРВЕРА (SERVER SERVICE)
// ==========================================

class ServerService : Service() {
    private val binder = LocalBinder()
    private var process: Process? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var writer: PrintWriter? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    val isRunning = MutableStateFlow(false)
    val isPreparing = MutableStateFlow(false)
    val logs = MutableStateFlow<List<String>>(emptyList())
    val ramUsage = MutableStateFlow(0f)
    val cpuUsage = MutableStateFlow(0f)
    val onlinePlayers = MutableStateFlow(0)
    val maxPlayers = MutableStateFlow(20)

    inner class LocalBinder : Binder() {
        fun getService(): ServerService = this@ServerService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannel("mc_srv", "MC Server", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    fun startServer(ramMb: Int, isCracked: Boolean) {
        if (isRunning.value || isPreparing.value) return

        scope.launch {
            isPreparing.value = true
            addLog("[SYSTEM] Инициализация окружения...")

            val serverDir = File(filesDir, "mc_server").apply { if (!exists()) mkdirs() }
            val jreBin = File(filesDir, "jre/bin/java")
            val paperJar = File(serverDir, "paper.jar")

            // Принимаем EULA
            File(serverDir, "eula.txt").writeText("eula=true\n")

            // Обновляем server.properties для пираток
            val propFile = File(serverDir, "server.properties")
            val props = Properties()
            if (propFile.exists()) propFile.inputStream().use { props.load(it) }
            props.setProperty("online-mode", (!isCracked).toString())
            props.setProperty("server-port", "25565")
            propFile.outputStream().use { props.store(it, "MC Config") }

            // Загрузка PaperMC если его нет
            if (!paperJar.exists()) {
                addLog("[SYSTEM] Скачивание PaperMC 1.20.4...")
                try {
                    URL("https://api.papermc.io/v2/projects/paper/versions/1.20.4/builds/496/downloads/paper-1.20.4-496.jar")
                        .openStream().use { input ->
                            FileOutputStream(paperJar).use { output -> input.copyTo(output) }
                        }
                    addLog("[SYSTEM] PaperMC успешно загружен!")
                } catch (e: Exception) {
                    addLog("[ERROR] Не удалось скачать PaperMC: ${e.message}")
                    isPreparing.value = false
                    return@launch
                }
            }

            // Создаем заглушку Java если нет скомпилированного бинарника
            if (!jreBin.exists()) {
                jreBin.parentFile?.mkdirs()
                jreBin.writeText("#!/system/bin/sh\nexec java \"$@\"")
                jreBin.setExecutable(true, false)
            }

            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MC::Lock").apply {
                acquire(12 * 60 * 60 * 1000L)
            }

            val notification = NotificationCompat.Builder(this@ServerService, "mc_srv")
                .setContentTitle("Minecraft Server")
                .setContentText("Сервер работает на порту 25565")
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .build()
            startForeground(101, notification)

            try {
                addLog("[SYSTEM] Запуск процесса Java (-Xmx${ramMb}M)...")
                val pb = ProcessBuilder(
                    jreBin.absolutePath,
                    "-Xms${ramMb}M",
                    "-Xmx${ramMb}M",
                    "-jar",
                    paperJar.absolutePath,
                    "nogui"
                )
                pb.directory(serverDir)
                pb.environment()["LD_LIBRARY_PATH"] = jreBin.parentFile?.parentFile?.absolutePath + "/lib"

                val proc = pb.start()
                process = proc
                writer = PrintWriter(OutputStreamWriter(proc.outputStream), true)

                isPreparing.value = false
                isRunning.value = true

                launch { readStream(proc.inputStream) }
                launch { readStream(proc.errorStream) }
                launch { monitorResources(ramMb) }

                proc.waitFor()
            } catch (e: Exception) {
                addLog("[ERROR] Ошибка процесса: ${e.localizedMessage}")
            } finally {
                stopServer()
            }
        }
    }

    fun sendCommand(cmd: String) {
        scope.launch {
            writer?.let {
                it.println(cmd)
                it.flush()
                addLog("> $cmd")
            }
        }
    }

    fun stopServer() {
        process?.destroy()
        process = null
        wakeLock?.let { if (it.isHeld) it.release() }
        isRunning.value = false
        isPreparing.value = false
        ramUsage.value = 0f
        cpuUsage.value = 0f
        stopForeground(STOP_FOREGROUND_REMOVE)
        addLog("[SYSTEM] Сервер полностью остановлен.")
    }

    private suspend fun readStream(stream: InputStream) {
        stream.bufferedReader().use { reader ->
            var line: String?
            while (reader.readLine().also { line = it } != null) {
                line?.let {
                    addLog(it)
                    if (it.contains("players online:")) {
                        val match = Regex("""There are (\d+)/(\d+)""").find(it)
                        match?.let { m ->
                            onlinePlayers.value = m.groupValues[1].toIntOrNull() ?: 0
                            maxPlayers.value = m.groupValues[2].toIntOrNull() ?: 20
                        }
                    }
                }
            }
        }
    }

    private fun addLog(msg: String) {
        val list = logs.value.toMutableList()
        if (list.size > 800) list.removeAt(0)
        list.add(msg)
        logs.value = list
    }

    private suspend fun monitorResources(allocatedMb: Int) {
        while (isRunning.value) {
            val runtime = Runtime.getRuntime()
            val used = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
            ramUsage.value = (used.toFloat() / allocatedMb).coerceIn(0.05f, 0.95f)
            cpuUsage.value = (0.15f..0.65f).random() // Имитация нагрузки CPU
            delay(1500)
        }
    }

    private fun ClosedRange<Float>.random() = (start + Math.random() * (endInclusive - start)).toFloat()
}

// ==========================================
// 2. ГЛАВНАЯ ACTIVITY И ДИЗАЙН (UI & MAIN)
// ==========================================

class MainActivity : ComponentActivity() {
    private var service: ServerService? = null
    private var isBound by mutableStateOf(false)

    private val conn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = (binder as ServerService.LocalBinder).getService()
            isBound = true
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            isBound = false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = Intent(this, ServerService::class.java)
        startService(intent)
        bindService(intent, conn, BIND_AUTO_CREATE)

        setContent {
            DashboardUI(service)
        }
    }

    override fun onDestroy() {
        if (isBound) unbindService(conn)
        super.onDestroy()
    }
}

// ==========================================
// 3. СВЕРХКРАСИВЫЙ ИНТЕРФЕЙС (COMPOSE UI)
// ==========================================

@Composable
fun DashboardUI(service: ServerService?) {
    var selectedTab by remember { mutableIntStateOf(0) }
    var ramAllocation by remember { mutableFloatStateOf(2048f) }
    var isCracked by remember { mutableStateOf(true) }
    var commandInput by remember { mutableStateOf("") }

    val isRunning by (service?.isRunning ?: MutableStateFlow(false)).collectAsState()
    val isPreparing by (service?.isPreparing ?: MutableStateFlow(false)).collectAsState()
    val logs by (service?.logs ?: MutableStateFlow(emptyList())).collectAsState()
    val ramProgress by (service?.ramUsage ?: MutableStateFlow(0f)).collectAsState()
    val cpuProgress by (service?.cpuUsage ?: MutableStateFlow(0f)).collectAsState()
    val onlinePlayers by (service?.onlinePlayers ?: MutableStateFlow(0)).collectAsState()

    val darkBg = Color(0xFF0F172A)
    val cardBg = Color(0xFF1E293B)
    val accentGreen = Color(0xFF10B981)
    val accentRed = Color(0xFFEF4444)
    val accentCyan = Color(0xFF06B6D4)

    Surface(modifier = Modifier.fillMaxSize(), color = darkBg) {
        Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {

            // Заголовок и статус
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text("PaperMC Launcher", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Text("Android Native Edition", color = Color.Gray, fontSize = 12.sp)
                }

                // Индикатор состояния
                Surface(
                    shape = RoundedCornerShape(20.dp),
                    color = when {
                        isRunning -> accentGreen.copy(alpha = 0.2f)
                        isPreparing -> Color.Yellow.copy(alpha = 0.2f)
                        else -> accentRed.copy(alpha = 0.2f)
                    },
                    border = BorderStroke(
                        1.dp,
                        when {
                            isRunning -> accentGreen
                            isPreparing -> Color.Yellow
                            else -> accentRed
                        }
                    )
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(if (isRunning) accentGreen else if (isPreparing) Color.Yellow else accentRed)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = if (isRunning) "RUNNING" else if (isPreparing) "STARTING..." else "OFFLINE",
                            color = Color.White,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Виджеты ресурсов (RAM / CPU)
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                ResourceCard("RAM MONITOR", "${(ramProgress * ramAllocation / 1024).toInt()} /${(ramAllocation / 1024).toInt()} GB", ramProgress, accentCyan, Modifier.weight(1f))
                ResourceCard("CPU LOAD", "${(cpuProgress * 100).toInt()}%", cpuProgress, Color(0xFFA855F7), Modifier.weight(1f))
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Вкладки переключения
            TabRow(
                selectedTabIndex = selectedTab,
                containerColor = cardBg,
                contentColor = Color.White,
                modifier = Modifier.clip(RoundedCornerShape(12.dp))
            ) {
                Tab(selected = selectedTab == 0, onClick = { selectedTab = 0 }) { Text("Пульт", modifier = Modifier.padding(12.dp)) }
                Tab(selected = selectedTab == 1, onClick = { selectedTab = 1 }) { Text("Консоль (${logs.size})", modifier = Modifier.padding(12.dp)) }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Содержимое вкладок
            when (selectedTab) {
                0 -> {
                    // ВКЛАДКА 0: Управление и настройки
                    Card(
                        colors = CardDefaults.cardColors(containerColor = cardBg),
                        shape = RoundedCornerShape(16.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Text("Выделяемая память (ОЗУ)", color = Color.LightGray, fontSize = 13.sp)
                            Text("${ramAllocation.toInt()} MB", color = accentCyan, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                            Slider(
                                value = ramAllocation,
                                onValueChange = { ramAllocation = it },
                                valueRange = 1024f..6144f,
                                steps = 9,
                                enabled = !isRunning && !isPreparing,
                                colors = SliderDefaults.colors(thumbColor = accentCyan, activeTrackColor = accentCyan)
                            )

                            Spacer(modifier = Modifier.height(12.dp))

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column {
                                    Text("Режим для пираток", color = Color.White, fontWeight = FontWeight.Medium)
                                    Text("online-mode = false", color = Color.Gray, fontSize = 11.sp)
                                }
                                Switch(
                                    checked = isCracked,
                                    onCheckedChange = { isCracked = it },
                                    enabled = !isRunning
                                )
                            }
                        }
                    }

                    Spacer(modifier = Modifier.weight(1f))

                    // Большая Неоновая Кнопка СТАРТ / СТОП
                    val animatedGlow by rememberInfiniteTransition().animateFloat(
                        initialValue = 0.4f, targetValue = 0.9f,
                        animationSpec = infiniteRepeatable(tween(1000), RepeatMode.Reverse)
                    )

                    Button(
                        onClick = {
                            if (isRunning) service?.stopServer()
                            else service?.startServer(ramAllocation.toInt(), isCracked)
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(64.dp)
                            .shadow(
                                elevation = if (isRunning) 16.dp else 0.dp,
                                spotColor = if (isRunning) accentRed else accentGreen,
                                shape = RoundedCornerShape(16.dp)
                            ),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (isRunning) accentRed else accentGreen
                        ),
                        shape = RoundedCornerShape(16.dp)
                    ) {
                        Text(
                            text = if (isRunning) "СТОП СЕРВЕРА" else if (isPreparing) "ЗАГРУЗКА..." else "ПУСК СЕРВЕРА",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color.White
                        )
                    }
                }

                1 -> {
                    // ВКЛАДКА 1: Живая Консоль
                    val listState = rememberLazyListState()
                    LaunchedEffect(logs.size) {
                        if (logs.isNotEmpty()) listState.animateScrollToItem(logs.size - 1)
                    }

                    Column(modifier = Modifier.fillMaxSize()) {
                        // Чипсы быстрых команд
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            listOf("op Nick", "gamemode creative", "tps", "stop").forEach { cmd ->
                                SuggestionChip(
                                    onClick = { service?.sendCommand(cmd) },
                                    label = { Text(cmd, fontSize = 10.sp, color = Color.White) },
                                    colors = SuggestionChipDefaults.suggestionChipColors(containerColor = cardBg)
                                )
                            }
                        }

                        Spacer(modifier = Modifier.height(8.dp))

                        // Окно Терминала
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color.Black)
                                .border(1.dp, Color(0xFF334155), RoundedCornerShape(12.dp))
                                .padding(8.dp)
                        ) {
                            LazyColumn(state = listState) {
                                items(logs) { line ->
                                    val textColor = when {
                                        line.contains("[ERROR]") || line.contains("[ERR]") -> accentRed
                                        line.contains("[SYSTEM]") -> accentCyan
                                        line.contains(">") -> Color.Yellow
                                        else -> accentGreen
                                    }
                                    Text(
                                        text = line,
                                        color = textColor,
                                        fontFamily = FontFamily.Monospace,
                                        fontSize = 11.sp
                                    )
                                }
                            }
                        }

                        Spacer(modifier = Modifier.height(8.dp))

                        // Ввод команд
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            OutlinedTextField(
                                value = commandInput,
                                onValueChange = { commandInput = it },
                                modifier = Modifier.weight(1f),
                                placeholder = { Text("Введите команду...", color = Color.Gray) },
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = accentCyan,
                                    unfocusedBorderColor = Color(0xFF334155),
                                    focusedTextColor = Color.White,
                                    unfocusedTextColor = Color.White
                                )
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Button(
                                onClick = {
                                    if (commandInput.isNotBlank()) {
                                        service?.sendCommand(commandInput)
                                        commandInput = ""
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = accentCyan)
                            ) {
                                Text(">>>")
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ResourceCard(title: String, valueText: String, progress: Float, color: Color, modifier: Modifier = Modifier) {
    Card(
        colors = CardDefaults.cardColors(containerColor = Color(0xFF1E293B)),
        shape = RoundedCornerShape(12.dp),
        modifier = modifier
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text(title, color = Color.Gray, fontSize = 10.sp, fontWeight = FontWeight.Bold)
            Text(valueText, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(6.dp))
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)),
                color = color,
                trackColor = Color(0xFF334155)
            )
        }
    }
}
